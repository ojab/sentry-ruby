# frozen_string_literal: true

begin
  require "httpx"
rescue LoadError
  return
end

module Sentry
  # @api private
  module HTTPX
    OP_NAME = "httpx"

    module Connection
      def send(request)
        binding.pry
        start_sentry_span
        set_sentry_trace_header(request)
        request.on(:response, &method(:on_response).curry.call[request])

        super
      end

      private

      def set_sentry_trace_header(req)
        return unless @sentry_span

        trace = Sentry.get_current_client.generate_sentry_trace(@sentry_span)
        req[SENTRY_TRACE_HEADER_NAME] = trace if trace
      end

      def on_response(request, response)
        record_sentry_breadcrumb(request, response)
        record_sentry_span(request, response)
      end

      def uri_with_filtered_pii(uri)
        uri = uri.dup
        uri.query = nil unless Sentry.configuration.send_default_pii

        uri
      end

      def record_sentry_breadcrumb(request, response)
        return unless Sentry.initialized? && Sentry.configuration.breadcrumbs_logger.include?(:http_logger)

        # request = response.request

        return if from_sentry_sdk?(request)

        crumb = Sentry::Breadcrumb.new(
          level: :info,
          category: OP_NAME,
          type: :info,
          data: {
            method: request.verb.to_s.upcase,
            url: uri_with_filtered_pii(request.uri),
            **response_data(response)
          }
        )
        Sentry.add_breadcrumb(crumb)
      end

      def response_data(response)
        if response.error
          {error: response.error.message}
        elsif Sentry.configuration.send_default_pii
          {status: response.status, body: response.body.read}
        else
          {status: response.status}
        end
      end

      def record_sentry_span(request, response)
        return unless Sentry.initialized? && @sentry_span

        @sentry_span.set_description("#{request.verb.to_s.upcase} #{uri_with_filtered_pii(request.uri)}")

        if response.error
          @sentry_span.set_data(:error, response.error.message)
        else
          @sentry_span.set_data(:status, response.status)
        end
      end

      def start_sentry_span
        return unless Sentry.initialized? && transaction = Sentry.get_current_scope.get_transaction

        return if from_sentry_sdk? || !transaction.sampled

        child_span = transaction.start_child(op: OP_NAME, start_timestamp: Sentry.utc_now.to_f)
        @sentry_span = child_span
      end

      def finish_sentry_span
        return unless Sentry.initialized? && @sentry_span

        @sentry_span.set_timestamp(Sentry.utc_now.to_f)
        @sentry_span = nil
      end

      def from_sentry_sdk?(request)
        Sentry.configuration.dsn&.host == request.uri.host
      end
    end
  end
end

Sentry.register_patch do
  binding.pry
  unless HTTPX::Connection.ancestors.include?(Sentry::HTTPX::Connection)
    HTTPX::Connection.prepend(Sentry::HTTPX::Connection)
  end
end
