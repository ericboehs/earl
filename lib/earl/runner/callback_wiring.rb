# frozen_string_literal: true

module Earl
  class Runner
    # Wires Claude session callbacks to streaming response handlers.
    module CallbackWiring
      # Bundles the session+thread_id pair that all callback wiring methods need.
      CallbackContext = Data.define(:session, :thread_id)

      private

      def wire_all_callbacks(bundle)
        session, _response, thread_id = bundle.deconstruct
        ctx = CallbackContext.new(session: session, thread_id: thread_id)
        last_tool = []
        wire_text_callback(ctx, last_tool)
        wire_tool_use_callback(ctx, last_tool)
        wire_tool_result_callback(ctx)
        wire_system_callback(ctx)
        wire_exit_callback(ctx)
        ctx.session.on_complete { |_| handle_response_complete(thread_id) }
      end

      def wire_text_callback(ctx, last_tool)
        detector = output_detector
        thread_id = ctx.thread_id
        ctx.session.on_text do |text|
          response = ensure_active_response(thread_id)
          tool_name = last_tool.pop
          refs = detect_images(detector, text, tool_name)
          log(:info, "wire_text_callback: tool=#{tool_name} refs=#{refs.size} text=#{text[0..60]}") unless refs.empty?
          response.on_text_with_images(text, refs)
        end
      end

      def wire_tool_use_callback(ctx, last_tool)
        thread_id = ctx.thread_id
        ctx.session.on_tool_use do |tool_use|
          response = ensure_active_response(thread_id)
          last_tool.replace([tool_use[:name]])
          response.on_tool_use(tool_use)
          handle_tool_use(thread_id: thread_id, tool_use: tool_use, channel_id: response.channel_id)
        end
      end

      def wire_system_callback(ctx)
        session, thread_id = ctx.deconstruct
        session.on_system do |event|
          response = ensure_active_response(thread_id)
          response.on_text(event[:message])
        end
      end

      def wire_tool_result_callback(ctx)
        detector = output_detector
        session, thread_id = ctx.deconstruct
        work_dir = session.working_dir
        session.on_tool_result do |tool_result|
          response = ensure_active_response(thread_id)
          refs = detect_inline(detector, tool_result, work_dir)
          response.add_image_refs(refs) unless refs.empty?
        end
      end

      def wire_exit_callback(ctx)
        thread_id = ctx.thread_id
        session = ctx.session
        session.on_exit do
          log(:debug, "Session #{thread_id[0..7]} reader exited — marking paused and releasing resources")
          @services.session_manager.suspend_session(thread_id, only_if: session)
          @app_state.message_queue.release(thread_id)
          response = @responses.active_responses.delete(thread_id)
          response&.stop_typing
        end
      end

      def detect_inline(detector, tool_result, work_dir)
        detector.detect_inline_images(tool_result[:images], texts: tool_result[:texts], working_dir: work_dir)
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
