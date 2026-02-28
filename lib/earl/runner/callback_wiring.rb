# frozen_string_literal: true

module Earl
  class Runner
    # Wires Claude session callbacks to streaming response handlers.
    module CallbackWiring
      private

      def wire_all_callbacks(bundle)
        last_tool = []
        wire_text_callback(bundle, last_tool)
        wire_tool_use_callback(bundle, last_tool)
        wire_tool_result_callback(bundle)
        wire_system_callback(bundle)
        bundle.session.on_complete { |_| handle_response_complete(bundle.thread_id) }
      end

      def wire_text_callback(bundle, last_tool)
        detector = output_detector
        response = bundle.response
        bundle.session.on_text do |text|
          tool_name = last_tool.pop
          refs = detect_images(detector, text, tool_name)
          log(:info, "wire_text_callback: tool=#{tool_name} refs=#{refs.size} text=#{text[0..60]}") unless refs.empty?
          response.on_text_with_images(text, refs)
        end
      end

      def wire_tool_use_callback(bundle, last_tool)
        session, _response, thread_id = bundle.deconstruct
        resp_channel_id, on_tool = extract_tool_use_context(bundle.response)
        session.on_tool_use do |tool_use|
          last_tool.replace([tool_use[:name]])
          on_tool.call(tool_use)
          handle_tool_use(thread_id: thread_id, tool_use: tool_use, channel_id: resp_channel_id)
        end
      end

      def extract_tool_use_context(response)
        [response.channel_id, response.method(:on_tool_use)]
      end

      def wire_system_callback(bundle)
        response = bundle.response
        bundle.session.on_system { |event| response.on_text(event[:message]) }
      end

      def wire_tool_result_callback(bundle)
        detector = output_detector
        session, response, _thread_id = bundle.deconstruct
        session.on_tool_result do |tool_result|
          refs = detector.detect_inline_images(tool_result[:images])
          response.add_image_refs(refs) unless refs.empty?
        end
      end

      def detect_images(detector, text, tool_name)
        return detector.detect_in_tool_result(tool_name, text) if tool_name

        detector.detect_in_text(text)
      end

      def output_detector
        @output_detector ||= ImageSupport::OutputDetector.new
      end
    end
  end
end
