# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module Earl
  module ImageSupport
    class OutputDetectorTest < Minitest::Test
      setup do
        Earl.logger = Logger.new(File::NULL)
        @detector = OutputDetector.new
      end

      teardown do
        Earl.logger = nil
      end

      # --- File path detection in tool results ---

      test "detects PNG file path in tool result text" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "chart.png")
          File.write(path, "fake png data")

          refs = @detector.detect_in_tool_result("Write", "Created file #{path} successfully")

          assert_equal 1, refs.size
          assert_equal :file_path, refs[0].source
          assert_equal path, refs[0].data
          assert_equal "image/png", refs[0].media_type
          assert_equal "chart.png", refs[0].filename
        end
      end

      test "detects JPEG file path in tool result text" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "photo.jpg")
          File.write(path, "fake jpg data")

          refs = @detector.detect_in_tool_result("Bash", "Output saved to #{path} done")

          assert_equal 1, refs.size
          assert_equal "image/jpeg", refs[0].media_type
          assert_equal "photo.jpg", refs[0].filename
        end
      end

      test "detects multiple image paths" do
        Dir.mktmpdir do |dir|
          png_path = File.join(dir, "a.png")
          gif_path = File.join(dir, "b.gif")
          File.write(png_path, "png")
          File.write(gif_path, "gif")

          refs = @detector.detect_in_tool_result("Bash", "#{png_path}\n#{gif_path}")

          assert_equal 2, refs.size
          assert_equal "image/png", refs[0].media_type
          assert_equal "image/gif", refs[1].media_type
        end
      end

      test "skips nonexistent file paths" do
        refs = @detector.detect_in_tool_result("Write", "/tmp/nonexistent_image_12345.png done")

        assert_empty refs
      end

      test "skips files exceeding 50MB" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "huge.png")
          File.write(path, "x" * ((50 * 1024 * 1024) + 1))

          refs = @detector.detect_in_tool_result("Write", "#{path} created")

          assert_empty refs
        end
      end

      test "returns empty array for nil input" do
        refs = @detector.detect_in_tool_result("Write", nil)

        assert_empty refs
      end

      # --- Base64 detection in screenshot tool results ---

      test "detects base64 PNG in screenshot tool result" do
        png_b64 = "iVBOR#{"A" * 200}"
        refs = @detector.detect_in_tool_result("browser_take_screenshot", "Image: #{png_b64}")

        assert_equal 1, refs.size
        assert_equal :base64, refs[0].source
        assert_equal "image/png", refs[0].media_type
        assert_equal "screenshot.png", refs[0].filename
      end

      test "detects base64 JPEG in screenshot tool result" do
        jpg_b64 = "/9j/#{"B" * 200}"
        refs = @detector.detect_in_tool_result("screenshot", "Data: #{jpg_b64}")

        assert_equal 1, refs.size
        assert_equal :base64, refs[0].source
        assert_equal "image/jpeg", refs[0].media_type
        assert_equal "screenshot.jpg", refs[0].filename
      end

      test "does not detect base64 in non-screenshot tool results" do
        png_b64 = "iVBOR#{"A" * 200}"
        refs = @detector.detect_in_tool_result("Write", "Data: #{png_b64}")

        assert_empty refs
      end

      test "ignores short base64 strings below threshold" do
        short_b64 = "iVBOR#{"A" * 10}"
        refs = @detector.detect_in_tool_result("browser_take_screenshot", short_b64)

        assert_empty refs
      end

      # --- Text-only detection ---

      test "detect_in_text finds file paths" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "output.webp")
          File.write(path, "webp data")

          refs = @detector.detect_in_text("Image saved to #{path} for you")

          assert_equal 1, refs.size
          assert_equal :file_path, refs[0].source
          assert_equal "image/webp", refs[0].media_type
        end
      end

      test "detect_in_text returns empty for nil" do
        refs = @detector.detect_in_text(nil)

        assert_empty refs
      end

      test "detect_in_text does not detect base64" do
        png_b64 = "iVBOR#{"A" * 200}"
        refs = @detector.detect_in_text("Data: #{png_b64}")

        assert_empty refs
      end

      # --- Media type mapping ---

      test "maps jpeg extension correctly" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "photo.jpeg")
          File.write(path, "jpeg data")

          refs = @detector.detect_in_text("#{path} ")

          assert_equal "image/jpeg", refs[0].media_type
        end
      end

      test "maps gif extension correctly" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "anim.gif")
          File.write(path, "gif data")

          refs = @detector.detect_in_text("#{path} ")

          assert_equal "image/gif", refs[0].media_type
        end
      end

      test "maps svg extension correctly" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "diagram.svg")
          File.write(path, "<svg></svg>")

          refs = @detector.detect_in_text("#{path} ")

          assert_equal 1, refs.size
          assert_equal "image/svg+xml", refs[0].media_type
          assert_equal "diagram.svg", refs[0].filename
        end
      end

      test "detects SVG file path in tool result text" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "chart.svg")
          File.write(path, "<svg></svg>")

          refs = @detector.detect_in_tool_result("Write", "Created #{path} successfully")

          assert_equal 1, refs.size
          assert_equal :file_path, refs[0].source
          assert_equal "image/svg+xml", refs[0].media_type
        end
      end

      # --- Markdown-wrapped path detection ---

      test "detects path wrapped in backticks" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "image.png")
          File.write(path, "png data")

          refs = @detector.detect_in_text("`#{path}`")

          assert_equal 1, refs.size
          assert_equal path, refs[0].data
        end
      end

      test "detects path wrapped in bold backticks" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "image.png")
          File.write(path, "png data")

          refs = @detector.detect_in_text("**`#{path}`**")

          assert_equal 1, refs.size
          assert_equal path, refs[0].data
        end
      end

      test "detects path followed by punctuation" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "image.png")
          File.write(path, "png data")

          refs = @detector.detect_in_text("Saved to #{path}.")

          assert_equal 1, refs.size
          assert_equal path, refs[0].data
        end
      end

      # --- Inline image detection (from tool_result content blocks) ---

      test "detect_inline_images extracts PNG image block" do
        blocks = [{ "type" => "image", "source" => { "data" => "iVBOR#{"A" * 200}", "media_type" => "image/png" } }]

        refs = @detector.detect_inline_images(blocks)

        assert_equal 1, refs.size
        assert_equal :base64, refs[0].source
        assert_equal "image/png", refs[0].media_type
        assert_equal "screenshot.png", refs[0].filename
        assert refs[0].data.start_with?("iVBOR")
      end

      test "detect_inline_images extracts JPEG image block" do
        blocks = [{ "type" => "image", "source" => { "data" => "/9j/#{"B" * 200}", "media_type" => "image/jpeg" } }]

        refs = @detector.detect_inline_images(blocks)

        assert_equal 1, refs.size
        assert_equal "image/jpeg", refs[0].media_type
        assert_equal "screenshot.jpg", refs[0].filename
      end

      test "detect_inline_images infers PNG when media_type is absent" do
        blocks = [{ "type" => "image", "source" => { "data" => "iVBOR#{"A" * 200}" } }]

        refs = @detector.detect_inline_images(blocks)

        assert_equal 1, refs.size
        assert_equal "image/png", refs[0].media_type
      end

      test "detect_inline_images infers JPEG from data prefix" do
        blocks = [{ "type" => "image", "source" => { "data" => "/9j/#{"C" * 200}" } }]

        refs = @detector.detect_inline_images(blocks)

        assert_equal 1, refs.size
        assert_equal "image/jpeg", refs[0].media_type
        assert_equal "screenshot.jpg", refs[0].filename
      end

      test "detect_inline_images skips blocks with short data" do
        blocks = [{ "type" => "image", "source" => { "data" => "iVBOR" } }]

        refs = @detector.detect_inline_images(blocks)

        assert_empty refs
      end

      test "detect_inline_images skips blocks with missing source data" do
        blocks = [{ "type" => "image", "source" => {} }]

        refs = @detector.detect_inline_images(blocks)

        assert_empty refs
      end

      test "detect_inline_images returns empty for nil input" do
        refs = @detector.detect_inline_images(nil)

        assert_empty refs
      end

      test "detect_inline_images handles multiple image blocks" do
        blocks = [
          { "type" => "image", "source" => { "data" => "iVBOR#{"A" * 200}", "media_type" => "image/png" } },
          { "type" => "image", "source" => { "data" => "/9j/#{"B" * 200}", "media_type" => "image/jpeg" } }
        ]

        refs = @detector.detect_inline_images(blocks)

        assert_equal 2, refs.size
        assert_equal "image/png", refs[0].media_type
        assert_equal "image/jpeg", refs[1].media_type
      end

      # --- File-path preference over inline base64 ---

      test "detect_inline_images prefers file paths from texts over inline base64" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "page-screenshot.png")
          File.write(path, "high-res png data")

          blocks = [{ "type" => "image", "source" => { "data" => "iVBOR#{"A" * 200}", "media_type" => "image/png" } }]

          refs = @detector.detect_inline_images(blocks, texts: [path.to_s], working_dir: nil)

          assert_equal 1, refs.size
          assert_equal :file_path, refs[0].source
          assert_equal path, refs[0].data
        end
      end

      test "detect_inline_images resolves relative paths with working_dir" do
        Dir.mktmpdir do |dir|
          subdir = File.join(dir, ".playwright-mcp")
          FileUtils.mkdir_p(subdir)
          path = File.join(subdir, "page-1.png")
          File.write(path, "screenshot data")

          blocks = [{ "type" => "image", "source" => { "data" => "iVBOR#{"A" * 200}", "media_type" => "image/png" } }]

          refs = @detector.detect_inline_images(blocks, texts: [".playwright-mcp/page-1.png"], working_dir: dir)

          assert_equal 1, refs.size
          assert_equal :file_path, refs[0].source
          assert_equal path, refs[0].data
          assert_equal "page-1.png", refs[0].filename
        end
      end

      test "detect_inline_images ignores relative paths without working_dir" do
        blocks = [{ "type" => "image", "source" => { "data" => "iVBOR#{"A" * 200}", "media_type" => "image/png" } }]

        refs = @detector.detect_inline_images(blocks, texts: [".playwright-mcp/page-1.png"], working_dir: nil)

        assert_equal 1, refs.size
        assert_equal :base64, refs[0].source
      end

      test "detect_inline_images falls back to base64 when texts have no valid paths" do
        blocks = [{ "type" => "image", "source" => { "data" => "iVBOR#{"A" * 200}", "media_type" => "image/png" } }]

        refs = @detector.detect_inline_images(blocks, texts: ["no image paths here"], working_dir: "/tmp")

        assert_equal 1, refs.size
        assert_equal :base64, refs[0].source
      end

      test "detect_inline_images handles absolute paths in texts" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "output.png")
          File.write(path, "png data")

          blocks = [{ "type" => "image", "source" => { "data" => "iVBOR#{"A" * 200}", "media_type" => "image/png" } }]

          refs = @detector.detect_inline_images(blocks, texts: ["Saved to #{path} successfully"], working_dir: nil)

          assert_equal 1, refs.size
          assert_equal :file_path, refs[0].source
          assert_equal path, refs[0].data
        end
      end

      test "detect_inline_images with empty texts falls back to base64" do
        blocks = [{ "type" => "image", "source" => { "data" => "iVBOR#{"A" * 200}", "media_type" => "image/png" } }]

        refs = @detector.detect_inline_images(blocks, texts: [], working_dir: "/tmp")

        assert_equal 1, refs.size
        assert_equal :base64, refs[0].source
      end

      test "detect_inline_images with nil texts falls back to base64" do
        blocks = [{ "type" => "image", "source" => { "data" => "iVBOR#{"A" * 200}", "media_type" => "image/png" } }]

        refs = @detector.detect_inline_images(blocks, texts: nil)

        assert_equal 1, refs.size
        assert_equal :base64, refs[0].source
      end
    end
  end
end
