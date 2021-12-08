# frozen_string_literal: true

require "net/http"

module Sentry
  # @api private
  module Net
    module HTTP
      OP_NAME = "net.http"

      # To explain how the entire thing works, we need to know how the original Net::HTTP#request works
      # Here's part of its definition. As you can see, it usually calls itself inside a #start block
      #
      # ```
      # def request(req, body = nil, &block)
      #   unless started?
      #     start {
      #       req['connection'] ||= 'close'
      #       return request(req, body, &block) # <- request will be called for the second time from the first call
      #     }
      #   end
      #   # .....
      # end
      # ```
      #
      # So we're only instrumenting request when `Net::HTTP` is already started
      def request(req, body = nil, &block)
        return super unless started?

        sentry_span = start_sentry_span
        set_sentry_trace_header(req, sentry_span)

        super.tap do |res|
          record_sentry_breadcrumb(req, res)
          record_sentry_span(req, res, sentry_span)
        end
      end

      private

      def set_sentry_trace_header(req, sentry_span)
        return unless sentry_span

        trace = Sentry.get_current_client.generate_sentry_trace(sentry_span)
        req[SENTRY_TRACE_HEADER_NAME] = trace if trace
      end

      def record_sentry_breadcrumb(req, res)
        return unless Sentry.initialized? && Sentry.configuration.breadcrumbs_logger.include?(:http_logger)
        return if from_sentry_sdk?

        request_info = extract_request_info(req)
        crumb = Sentry::Breadcrumb.new(
          level: :info,
          category: OP_NAME,
          type: :info,
          data: {
            method: request_info[:method],
            url: request_info[:url],
            status: res.code.to_i
          }
        )
        Sentry.add_breadcrumb(crumb)
      end

      def record_sentry_span(req, res, sentry_span)
        return unless Sentry.initialized? && sentry_span

        request_info = extract_request_info(req)
        sentry_span.set_description("#{request_info[:method]} #{request_info[:url]}")
        sentry_span.set_data(:status, res.code.to_i)
        finish_sentry_span(sentry_span)
      end

      def start_sentry_span
        return unless Sentry.initialized? && transaction = Sentry.get_current_scope.get_transaction
        return if from_sentry_sdk?
        return if transaction.sampled == false

        transaction.start_child(op: OP_NAME, start_timestamp: Sentry.utc_now.to_f)
      end

      def finish_sentry_span(sentry_span)
        return unless Sentry.initialized? && sentry_span

        sentry_span.set_timestamp(Sentry.utc_now.to_f)
      end

      def from_sentry_sdk?
        dsn = Sentry.configuration.dsn
        dsn && dsn.host == self.address
      end

      def extract_request_info(req)
        uri = req.uri || URI.parse("#{use_ssl? ? 'https' : 'http'}://#{address}#{req.path}")
        url = "#{uri.scheme}://#{uri.host}#{uri.path}"
        url = "#{url}?#{uri.query}" if uri.query && Sentry.configuration.send_default_pii

        { method: req.method, url: url }
      rescue
        { method: req.method, url: url.to_s }
      end
    end
  end
end

Sentry.register_patch do
  patch = Sentry::Net::HTTP
  Net::HTTP.send(:prepend, patch) unless Net::HTTP.ancestors.include?(patch)
end
