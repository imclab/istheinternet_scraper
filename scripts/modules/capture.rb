require "selenium-webdriver"

module IsTheInternet
  module Page
    class Capture

      include Sidekiq::Worker


      def initialize(url,force=[])
        @url = url
        @force_process = force || []
        capture!
      end

      # Create driver connection
      def driver(b=:remote,o=nil)
        o ||= {url: 'http://localhost:9134'}
        @driver ||= Selenium::WebDriver.for(b,o)
      end

      # Stop the driver and remove the association
      def stop_driver
        @driver.quit rescue nil
        @driver = nil
      end

      # Parse URL
      def uri
        return @uri unless @uri.blank?
        @uri = Addressable::URI.parse(@url) rescue false
      end

      # Parse URL host
      def uri_host
        return @uri_host unless @uri_host.blank?
        if uri.present?
          p = uri.host.gsub(/\Awww\./, '').downcase rescue ''
        end
        @uri_host = (p.blank? ? '' : p)
      end

      # Parse URL path
      def uri_path
        return @uri_path unless @uri_path.blank?
        if uri.present?
          p = (uri.path || '').downcase rescue ''
          p << "?#{uri.query}" if uri.query.present?
          p << "##{uri.fragment}" if uri.fragment.present?
        end
        @uri_path = (p.blank? ? '/' : p)
      end

      # Find or create the WebSite
      def web_site
        return @web_site unless @web_site.blank?
        @web_site = WebSite.where('LOWER(host_url) = ?', uri_host.downcase).first rescue nil
        @web_site ||= WebSite.new(url: uri, host_url: uri_host)

        if @web_site.new_record?
          # scrape robots
          @web_site.save
        end

        @web_site
      end

      # Find or create the WebPage
      def web_page
        return @web_page unless @web_page.blank?
        @web_page = web_site.web_pages.where('LOWER(path) = ?', uri_path.downcase).first rescue nil
        @web_page ||= web_site.web_pages.build(path: uri_path, url: uri)
        
        if @web_page.new_record?
          # We need to call the page to get correct status, headers, etc. WebDriver does not support this.
          begin
            io = open(uri, read_timeout: 15, "User-Agent" => CRAWLER_USER_AGENT, allow_redirections: :all)
            raise "Invalid content-type" unless io.content_type.match(/text\/html/i)

            # Additional information
            @web_page.assign_attributes(
              headers: io.meta.to_hash,
              base_uri: io.base_uri.to_s, # redirect?
              last_modified_at: io.last_modified,
              charset: io.charset,
              page_status: io.status[0],
              available: true
            )
          rescue => err # OpenURI::HTTPError => err
            @web_page.update_attribute(available: false)
            raise err
          end

          @web_page.save
        end

        @web_page
      end

      # Temporary File Name
      def tmp_filename
        "#{APP_ROOT}/tmp/#{web_page.id}.png"
      end

      # -----------------------------------------------------------------------

      # Mark web page as new
      # def capture_none
      #   web_page.step!(:none)
      # end

      # Mark web page as new
      def capture_complete
        web_page.step!(:complete)
      end

      # Capture and save screenshot
      def capture_screenshot
        driver.save_screenshot(tmp_filename)
        web_page.screenshot = open(tmp_filename)

        raise "Unable to screenshot." unless web_page.step!(:screenshot)
        _debug("...done!", 1, [web_page])
      end


      # Process the current web page for colors
      def capture_process
        raise "Screenshot not found." if web_page.screenshot_file_size.blank? || web_page.screenshot_file_size < 1

        color_palette = web_page.color_palette rescue nil
        color_palette ||= web_page.build_color_palette

        # --- Dominant Color & Palette ---
        img = Magick::ImageList.new
        img_file = File.open(tmp_filename, "r") if File.exists?(tmp_filename)
        img_file ||= open(web_page.screenshot.url(:pixel), read_timeout: 5, "User-Agent" => CRAWLER_USER_AGENT)
        img.from_blob(img_file.read)
        img.delete_profile('*')
        palette = img.quantize(10).color_histogram.sort{|a,b| b.last <=> a.last}
        primary = palette[0][0]

        color_palette.assign_attributes({
          dominant_color: [rgb(primary.red), rgb(primary.green), rgb(primary.blue)],
          dominant_color_red: rgb(primary.red),
          dominant_color_green: rgb(primary.blue),
          dominant_color_blue: rgb(primary.green),
          color_palette: palette.map{|p,c,r| [rgb(p.red), rgb(p.green), rgb(p.blue)]}
        })
        raise "Unable to save palette colors." unless color_palette.save

        # --- Pixel ---
        img = Magick::ImageList.new
        pixel_img = web_page.screenshot.url(:pixel) if USE_S3 # TODO : better check
        pixel_img ||= File.join(APP_ROOT,web_page.screenshot.path(:pixel))
        img.from_blob(open(pixel_img, read_timeout: 5, "User-Agent" => CRAWLER_USER_AGENT).read)
        img.delete_profile('*')
        primary = img.pixel_color(0,0)

        color_palette.assign_attributes({
          pixel_color: [rgb(primary.red), rgb(primary.green), rgb(primary.blue)],
          pixel_color_red: rgb(primary.red),
          pixel_color_green: rgb(primary.blue),
          pixel_color_blue: rgb(primary.green)
        })
        raise "Unable to save pixel color." unless color_palette.save

        raise "Unable to process." unless web_page.step!(:process)
        _debug("...done!", 1, [web_page])
      end


      # Scrape the current web page
      def capture_scrape
        io = StringIO.new(driver.page_source)
        io.class_eval { attr_accessor :original_filename }
        io.original_filename = [File.basename(web_page.filename), "html"].join('.')
        web_page.html_page = io

        raise "Unable to scrape." unless web_page.step!(:scrape)
        _debug("...done!", 1, [web_page])
      end


      # Parse the current page for additional links to add into the queue
      def capture_parse
        # TODO
        # web_page.title = page.css('title').to_s
        # web_page.meta_tags = page.css('meta').map{|m| t = {}; m.attributes.each{|k,v| t[k] = v.to_s}; t }
        # 
        # follow = page.css('meta[name="robots"]')[0].attributes['content'].to_s rescue 'index,follow'
        # page.css('a[href]').each{|h| PageQueue::add(h.attributes['href']) } unless follow.match(/nofollow/i)

        raise "Unable to parse." unless web_page.step!(:parse)
        _debug("...done!", 1, [web_page])
      end

      # Initially open the web page in WebDriver
      def open_web_page
        raise "URL is invalid: #{@url}" if uri.blank?
        raise "Web Site is invalid: #{@url}" if web_site.blank? || web_site.new_record?
        raise "Web Page is invalid: #{@url}" if web_page.blank? || web_page.new_record?

        _debug("Opening", 1, [web_page])
        driver.manage.window.resize_to(1280, 800)
        driver.navigate.to(web_page.base_uri)
      end


      # -----------------------------------------------------------------------

      # Capture the URL and run through the steps
      def capture!
        begin
          _debug("Capturing #{uri}", 0, [web_page])

          # if web_page.step?(:complete) && @force_process.blank?
          #   _debug("Previously completed!", 1, [web_page])
          #   return
          # end

          Timeout::timeout(120) do # 120 seconds
            # Open up the web page, ensure if valid
            open_web_page

            # Go through each step
            WebPage::STEPS.each do |v|
              # next if web_page.step?(v) && !@force_process.include?(v)

              n = "capture_#{v}"
              if respond_to?(n)
                _debug(v.to_s.capitalize, 1, [web_page])
                send(n)
              end
            end
          end

        rescue Timeout::Error => err
          _error("Timeout error: #{err}", 1)

        rescue => err
          _error(err, 1)

        ensure
          stop_driver rescue nil
          File.unlink(tmp_filename) rescue nil
        end

      end

      protected

        def rgb(i=0)
          (@q18 || i > 255 ? ((255*i)/65535) : i).round
        end

    end
  end
end