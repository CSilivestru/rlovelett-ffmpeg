require 'time'
require 'multi_json'

module FFMPEG
  class Movie
    attr_reader :path, :duration, :time, :bitrate, :rotation, :creation_time
    attr_reader :video_stream, :video_codec, :video_bitrate, :colorspace, :width, :height, :sar, :dar, :frame_rate, :has_b_frames, :video_profile, :video_level
    attr_reader :all_audio_streams, :audio_stream, :audio_codec, :audio_bitrate, :audio_sample_rate, :audio_channels
    attr_reader :container
    attr_reader :error

    def initialize(path)
      unless File.exists?(path) || path =~ URI::regexp(["http", "https"])
        raise Errno::ENOENT, "the file '#{path}' does not exist"
      end

      @path = path

      # ffmpeg will output to stderr
      command = "#{FFMPEG.ffprobe_binary} -i #{Shellwords.escape(path)} -print_format json -show_format -show_streams -show_error"
      std_output = ''
      std_error = ''

      Open3.popen3(command) do |stdin, stdout, stderr|
        std_output = stdout.read unless stdout.nil?
        std_error = stderr.read unless stderr.nil?
      end

      fix_encoding(std_output)

      metadata = MultiJson.load(std_output, symbolize_keys: true)

      if metadata.key?(:error)
        @error = metadata[:error][:string]
        @duration = 0
      else
        video_streams = metadata[:streams].select { |stream| stream.key?(:codec_type) and stream[:codec_type] === 'video' }
        audio_streams = metadata[:streams].select { |stream| stream.key?(:codec_type) and stream[:codec_type] === 'audio' }

        @container = metadata[:format][:format_name]

        @duration = metadata[:format][:duration].to_f

        @time = metadata[:format][:start_time].to_f

        @creation_time = if metadata[:format].key?(:tags) and metadata[:format][:tags].key?(:creation_time)
                           Time.parse(metadata[:format][:tags][:creation_time])
                         else
                           nil
                         end

        @bitrate = metadata[:format][:bit_rate].to_i
        @size = metadata[:format][:size].to_i

        unless video_streams.empty?
          # TODO: Handle multiple video codecs (is that possible?)
          video_stream = video_streams.first
          @video_codec = video_stream[:codec_name]
          @colorspace = video_stream[:pix_fmt]
          @width = video_stream[:width]
          @height = video_stream[:height]
          @video_bitrate = video_stream[:bit_rate].to_i
          @sar = video_stream[:sample_aspect_ratio]
          @dar = video_stream[:display_aspect_ratio]
          @has_b_frames = video_stream[:has_b_frames].to_i
          @video_profile = video_stream[:profile]
          @video_level = video_stream[:level] / 10.0 unless video_stream[:level].nil?

          @frame_rate = unless video_stream[:avg_frame_rate] == '0/0'
                          Rational(video_stream[:avg_frame_rate])
                        else
                          nil
                        end

          @video_stream = "#{video_stream[:codec_name]} (#{video_stream[:profile]}) (#{video_stream[:codec_tag_string]} / #{video_stream[:codec_tag]}), #{colorspace}, #{resolution} [SAR #{sar} DAR #{dar}]"

          @rotation = if video_stream.key?(:tags) and video_stream[:tags].key?(:rotate)
                        video_stream[:tags][:rotate].to_i
                      else
                        nil
                      end
        end

        unless audio_streams.empty?
          @all_audio_streams = audio_streams.map do |stream|
            {
              :channels => stream[:channels].to_i,
              :codec_name => stream[:codec_name],
              :sample_rate => stream[:sample_rate].to_i,
              :bitrate => stream[:bit_rate].to_i,
              :channel_layout => stream[:channel_layout],
              :stream_overview => "#{stream[:codec_name]} (#{stream[:codec_tag_string]} / #{stream[:codec_tag]}), #{stream[:sample_rate].to_i} Hz, #{stream[:channel_layout]}, #{stream[:sample_fmt]}, #{stream[:bit_rate].to_i} bit/s"
            }
          end

          audio_stream = @all_audio_streams.first
          @audio_channels = audio_stream[:channels]
          @audio_codec = audio_stream[:codec_name]
          @audio_sample_rate = audio_stream[:sample_rate]
          @audio_bitrate = audio_stream[:bitrate]
          @audio_channel_layout = audio_stream[:channel_layout]
          @audio_stream = audio_stream[:stream_overview]
        end
      end

      @invalid = true if metadata.key?(:error)
      @invalid = true if std_error.include?("Unsupported codec")
      @invalid = true if std_error.include?("is not supported")
      @invalid = true if std_error.include?("could not find codec parameters")
    end

    def valid?
      not @invalid
    end

    def resolution
      unless width.nil? or height.nil?
        "#{width}x#{height}"
      end
    end

    def calculated_aspect_ratio
      aspect_from_dar || aspect_from_dimensions
    end

    def calculated_pixel_aspect_ratio
      aspect_from_sar || 1
    end

    def size
      if @size
        @size
      else
        File.size(@path)
      end
    end

    def audio_channel_layout
      # TODO Whenever support for ffmpeg/ffprobe 1.2.1 is dropped this is no longer needed
      @audio_channel_layout || case(audio_channels)
                                 when 1
                                   'stereo'
                                 when 2
                                   'stereo'
                                 when 6
                                   '5.1'
                                 else
                                   'unknown'
                               end
    end

    def portrait?
      width && height && (height > width)
    end

    def landscape?
      width && height && (width > height)
    end

    def transcode(output_file, options = EncodingOptions.new, transcoder_options = {}, &block)
      Transcoder.new(self, output_file, options, transcoder_options).run &block
    end

    def screenshot(output_file, options = EncodingOptions.new, transcoder_options = {}, &block)
      Transcoder.new(self, output_file, options.merge(screenshot: true), transcoder_options).run &block
    end

    protected
    def aspect_from_dar
      return nil unless dar
      w, h = dar.split(":")
      aspect = w.to_f / h.to_f
      aspect.zero? ? nil : aspect
    end

    def aspect_from_sar
      return nil unless sar
      w, h = sar.split(":")
      aspect = w.to_f / h.to_f
      aspect.zero? ? nil : aspect
    end

    def aspect_from_dimensions
      aspect = width.to_f / height.to_f
      aspect.nan? ? nil : aspect
    end

    def fix_encoding(output)
      output[/test/] # Running a regexp on the string throws error if it's not UTF-8
    rescue ArgumentError
      output.force_encoding("ISO-8859-1")
    end
  end
end
