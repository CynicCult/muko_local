require 'sketchup.rb'
require 'extensions.rb'
require 'fileutils'
require 'net/http'
require 'json'
require 'uri'
require 'securerandom'
require 'cgi'

module MukoRender
  module MukoMain
    # ==========================================
    # 1. REGISTRASI EXTENSION MANAGER
    # ==========================================
    unless file_loaded?("muko_ai_registration")
      # Mendaftarkan file ini sendiri agar muncul detailnya di Extension Manager
      ex = SketchupExtension.new('Muko AI', __FILE__)
      ex.description = 'Plugin Muko AI untuk rendering arsitektur terintegrasi dengan ComfyUI.'
      ex.version     = '1.0.0'
      ex.copyright   = '© 2026 Muko'
      ex.creator     = 'Muko Team'
      
      Sketchup.register_extension(ex, true)
      file_loaded("muko_ai_registration")
    end

    # ==========================================
    # 2. KODE UTAMA PLUGIN
    # ==========================================
    EXTENSION_NAME = "Muko AI"
    DEFAULT_DETAIL_MM = 1000.0
    
    # Path disesuaikan dengan struktur Anda (assets di dalam muko_files)
    UI_DIR = File.join(__dir__, "muko_main")
    ASSETS_DIR = File.join(UI_DIR, "assets")
    UI_FILE = File.join(UI_DIR, "index.html")
    
    # ComfyUI Local Configuration
    COMFYUI_URL = "http://127.0.0.1:8000"
    WORKFLOW_FILE = File.join(UI_DIR, "api.json")
    RENDERS_DIR = File.join(ENV['TEMP'] || ENV['TMP'] || '/tmp', 'muko_renders')

    GOOGLE_CLIENT_ID = "1074133117385-33tag15q3pb4fbb3d1saqjub6e5li6p9.apps.googleusercontent.com"
    GOOGLE_CLIENT_SECRET = "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"
    GOOGLE_REDIRECT_PORT = 9876
    GOOGLE_REDIRECT_PATH = "/oauth/callback"
    GOOGLE_REDIRECT_URI = "http://127.0.0.1:#{GOOGLE_REDIRECT_PORT}#{GOOGLE_REDIRECT_PATH}"
    GOOGLE_AUTH_URI = "https://accounts.google.com/o/oauth2/auth"
    GOOGLE_TOKEN_URI = "https://oauth2.googleapis.com/token"
    GOOGLE_USERINFO_URI = "https://www.googleapis.com/oauth2/v2/userinfo"

    AUTH_DATA_FILE = File.join(UI_DIR, "user_session.json")

    # Panggil fungsi ini saat open_dialog pertama kali dijalankan
    def self.load_saved_session(dialog = nil)
      if File.exist?(AUTH_DATA_FILE)
        begin
          data = JSON.parse(File.read(AUTH_DATA_FILE))
          # Kirim data ke UI jika session masih valid
          script = "window.onGoogleOAuthSuccess('#{escape_js(data['name'])}', '#{escape_js(data['email'])}', '#{escape_js(data['photo'])}')"
          if dialog
            dialog.execute_script(script)
          else
            safe_execute(script)
          end
        rescue
          File.delete(AUTH_DATA_FILE)
        end
      end
    end

    # Simpan sesi login agar tetap login saat plugin dibuka ulang
    def self.on_login_success(name, email, photo)
      ensure_ui_dir
      session_data = { name: name, email: email, photo: photo, login_time: Time.now.to_i }
      File.write(AUTH_DATA_FILE, session_data.to_json)
    rescue => e
      puts "[Muko] Failed to save login session: #{e.message}"
    end

    def self.logout(dialog = nil)
      File.delete(AUTH_DATA_FILE) if File.exist?(AUTH_DATA_FILE)
    rescue => e
      puts "[Muko] Failed to clear login session: #{e.message}"
    end

    RAB_DICT_NAME = "muko_rab"
    RAB_STATE_KEY = "state_json"
    GROQ_API_KEY = "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"
    GROQ_ENDPOINT = "https://api.groq.com/openai/v1/chat/completions"
    GROQ_MODEL = "llama-3.1-8b-instant"

    def self.detail_length
      @detail_length ||= DEFAULT_DETAIL_MM
    end

    def self.detail_length=(value)
      @detail_length = value
    end

    def self.ensure_assets_dir
      FileUtils.mkdir_p(ASSETS_DIR) unless File.directory?(ASSETS_DIR)
    end

    def self.ensure_ui_dir
      FileUtils.mkdir_p(UI_DIR) unless File.directory?(UI_DIR)
    end

    def self.open_dialog
      unless @dialog
        @dialog = UI::HtmlDialog.new(
          dialog_title: EXTENSION_NAME,
          preferences_key: "MukoAI",
          scrollable: true,
          resizable: false,
          width: 468,
          height: 720,
          style: UI::HtmlDialog::STYLE_DIALOG
        )
        setup_dialog_callbacks(@dialog)
        @dialog.set_file(UI_FILE)
      end
      
      @dialog.show
      UI.start_timer(0.1, false) { 
        load_saved_session
        safe_execute("muko.openMukoAI()") if @dialog
      }
    end
    
    def self.setup_dialog_callbacks(dialog)

      dialog.add_action_callback("open_link") { |_ctx|
        UI.openURL("https://link.com")
      }

      dialog.add_action_callback("login_google") { |_ctx|
        dialog.execute_script("setStatusText('Membuka login Google...')")
        start_google_oauth(dialog)
      }

      dialog.add_action_callback("start_google_oauth") { |_ctx|
        dialog.execute_script("setStatusText('Membuka login Google...')")
        start_google_oauth(dialog)
      }

      dialog.add_action_callback("login_guest") { |_ctx|
        guest_login(dialog)
      }

      dialog.add_action_callback("capture_scene") { |_ctx|
        capture_view(dialog)
      }

      dialog.add_action_callback("upload_image") { |_ctx|
        upload_custom_image(dialog)
      }

      dialog.add_action_callback("download_result") { |_ctx|
        download_result(dialog)
      }

      dialog.add_action_callback("render_ai") { |_ctx, detail_value|
        render_scene(detail_value, dialog)
      }

      dialog.add_action_callback("logout") { |_ctx|
        logout(dialog)
      }

      dialog.add_action_callback("load_saved_session") { |_ctx|
        load_saved_session(dialog)
      }
    end
    
    def self.guest_login(dialog = @dialog)
      name = "Guest User"
      email = "guest@muko.local"
      photo = ""
      dialog&.execute_script("window.onGoogleOAuthSuccess('#{escape_js(name)}', '#{escape_js(email)}', '#{escape_js(photo)}')")
    end

    def self.capture_view(dialog = @dialog)
      model = Sketchup.active_model
      view = model.active_view

      temp_dir = File.join(ENV['TEMP'] || ENV['TMP'] || '/tmp', 'muko_captures')
      FileUtils.mkdir_p(temp_dir) unless File.directory?(temp_dir)

      timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
      filename = "muko_capture_#{timestamp}.png"
      path = File.join(temp_dir, filename)

      options = {
        filename: path,
        width: view.vpwidth,
        height: view.vpheight,
        antialias: true
      }

      if view.write_image(options)
        @last_capture = path
        @capture_source = :capture
        
        # --- TAMBAHKAN BARIS INI UNTUK FIX BUG ---
        @last_result = nil # Menghapus data hasil render lama dari memori Ruby
        
        escaped_path = path.gsub('\\', '/')
        
        # Kita panggil fungsi reset UI di JS (pastikan nama fungsi di index.html sama)
        safe_execute("setBeforeAfter('file:///#{escaped_path}', '')") 
        safe_execute("setStatusText('Capture berhasil')")
        # -----------------------------------------
      else
        safe_execute("setStatusText('❌ Gagal capture')")
      end
    end

    def self.upload_custom_image(dialog = @dialog)

      filters = "Image Files|*.png;*.jpg;*.jpeg;*.bmp;*.tif;*.tiff||"

      path = UI.openpanel("Pilih gambar", nil, filters)

      return unless path



      @last_capture = path

      @capture_source = :upload

      

      # --- TAMBAHKAN BARIS INI ---

      @last_result = nil 

      

      escaped_path = path.gsub('\\', '/')

      safe_execute("setBeforeAfter('file:///#{escaped_path}', '')")

      safe_execute("setStatusText('Gambar custom dipilih')")

    end

    def self.download_result(dialog = @dialog)
      unless @last_result && File.exist?(@last_result)
        safe_execute("setStatusText('❌ Tidak ada hasil untuk didownload')")
        return
      end

      default_name = "muko_render_#{Time.now.strftime('%Y%m%d_%H%M%S')}.png"
      save_path = UI.savepanel("Simpan Hasil Render", nil, default_name)
      return unless save_path

      begin
        FileUtils.cp(@last_result, save_path)
        safe_execute("setStatusText('✅ Hasil disimpan ke: #{File.basename(save_path)}')")
      rescue => e
        safe_execute("setStatusText('❌ Gagal menyimpan: #{escape_js(e.message)}')")
      end
    end

    def self.configure_detail
      prompts = ["Masukkan Detail (mm):"]
      defaults = [detail_length.to_s]
      input = UI.inputbox(prompts, defaults, "Muko - Skala")
      return unless input

      value = input[0].to_f
      if value <= 0
        UI.messagebox("⚠️ Nilai detail harus lebih besar dari 0.")
      else
        self.detail_length = value
        @dialog&.execute_script("document.getElementById('detailInput').value = #{detail_length}")
        @dialog&.execute_script("setStatusText('Detail: #{detail_length} mm')")
      end
    end

    def self.render_scene(detail_value, dialog = @dialog)
      puts "[Muko] render_scene called with detail: #{detail_value}"

      if @render_in_progress
        safe_execute("setStatusText('⏳ Render sedang berjalan...')")
        return
      end

      value = detail_value.to_f
      if value <= 0
        UI.messagebox("⚠️ Nilai detail harus lebih besar dari 0.")
        return
      end

      self.detail_length = value

      unless @last_capture && File.exist?(@last_capture)
        puts "[Muko] No capture found: #{@last_capture.inspect}"
        safe_execute("setStatusText('❌ Capture scene dulu sebelum render')")
        return
      end

      puts "[Muko] Starting render with capture: #{@last_capture}"

      @render_in_progress = true
      safe_execute("startMatrixAnimation()")
      safe_execute("setStatusText('🚀 Mengirim ke ComfyUI...')")

      puts "[Muko] Starting async render..."
      
      # Phase 1: Upload & Queue (quick, non-blocking)
      UI.start_timer(0.1, false) do
        begin
          puts "[Muko] Uploading and queuing prompt..."
          @render_start_time = Time.now
          @render_poll_count = 0
          @render_prompt_id = upload_and_queue(@last_capture)
          
          puts "[Muko] Prompt queued: #{@render_prompt_id}"
          
          # Phase 2: Start async polling (3 seconds interval)
          start_render_polling
          
        rescue => e
          puts "[Muko] ❌ UPLOAD ERROR: #{e.class} - #{e.message}"
          puts e.backtrace.join("\n  ")
          safe_execute("stopMatrixAnimation()")
          safe_execute("setStatusText('❌ Upload gagal: #{escape_js(e.message)}')")
          @render_in_progress = false
        end
      end
      
      puts "[Muko] Async render started, SketchUp should stay responsive"
    end

    def self.start_google_oauth(dialog = @dialog)
      return if @oauth_in_progress

      @oauth_in_progress = true
      @oauth_state = SecureRandom.hex(16)
      @oauth_stop = false
      @oauth_dialog = dialog

      begin
        start_oauth_server
        auth_url = build_google_auth_url(@oauth_state)
        UI.openURL(auth_url)
        dialog&.execute_script("setStatusText('Silakan login di browser...')")
      rescue => e
        dialog&.execute_script("window.onGoogleOAuthError('Gagal memulai OAuth: #{escape_js(e.message)}')")
        @oauth_in_progress = false
        @oauth_stop = true
      end
    end

    def self.stop_oauth_server
      @oauth_stop = true
      @oauth_in_progress = false
      UI.stop_timer(@oauth_timer) if @oauth_timer
      @oauth_server&.close rescue nil
      @oauth_server = nil
      @oauth_timer = nil
    end

    def self.build_google_auth_url(state)
      params = {
        client_id: GOOGLE_CLIENT_ID,
        redirect_uri: GOOGLE_REDIRECT_URI,
        response_type: 'code',
        scope: 'openid email profile',
        access_type: 'offline',
        prompt: 'consent',
        state: state
      }
      query = params.map { |key, value| "#{CGI.escape(key.to_s)}=#{CGI.escape(value.to_s)}" }.join('&')
      "#{GOOGLE_AUTH_URI}?#{query}"
    end

    def self.start_oauth_server
      begin
        @oauth_server = TCPServer.new('127.0.0.1', GOOGLE_REDIRECT_PORT)
        puts "[Muko] OAuth server started on port #{GOOGLE_REDIRECT_PORT}"
        
        # Start non-blocking polling timer (every 0.5 seconds)
        @oauth_start_time = Time.now
        @oauth_timer = UI.start_timer(0.5, true) do
          poll_oauth_server
        end
      rescue => e
        puts "[Muko] Failed to start OAuth server: #{e.message}"
        @oauth_dialog&.execute_script("window.onGoogleOAuthError('Gagal start server: #{escape_js(e.message)}')")
        @oauth_in_progress = false
        raise
      end
    end

    def self.poll_oauth_server
      # Timeout after 60 seconds
      if Time.now - @oauth_start_time > 60
        puts "[Muko] OAuth timeout"
        @oauth_dialog&.execute_script("window.onGoogleOAuthError('⏱️ Login timeout. Silakan coba lagi.')")
        stop_oauth_server
        return
      end

      # Stop if flag set
      if @oauth_stop
        stop_oauth_server
        return
      end

      begin
        # Non-blocking accept
        client = @oauth_server.accept_nonblock
        
        # Read request
        request_line = client.gets
        unless request_line
          client.close
          return
        end

        # Read and discard headers
        while (header = client.gets)
          break if header.strip.empty?
        end

        method, full_path = request_line.split(' ', 3)
        path, query = full_path.split('?', 2)
        params = CGI.parse(query.to_s)

        puts "[Muko] Received request: #{path}"
        puts "[Muko] Params: #{params.inspect}"

        if path != GOOGLE_REDIRECT_PATH
          html = build_callback_html('Path Tidak Valid', 'URL callback tidak sesuai. Pastikan redirect URI sudah dikonfigurasi dengan benar.', 'error', false)
          write_http_response(client, 404, 'Not Found', html)
          client.close
          stop_oauth_server
          return
        end

        if params['state']&.first != @oauth_state
          html = build_callback_html('Keamanan Gagal', 'State OAuth tidak valid. Silakan coba login kembali.', 'error', false)
          write_http_response(client, 400, 'Bad Request', html)
          @oauth_dialog&.execute_script("window.onGoogleOAuthError('⚠️ State OAuth tidak valid. Silakan coba lagi.')")
          client.close
          stop_oauth_server
          return
        end

        if params['error'] && params['error'].first
          message = params['error_description']&.first || params['error']&.first
          html = build_callback_html('Login Dibatalkan', 'Anda membatalkan proses login. Silakan tutup tab ini dan coba lagi dari SketchUp.', 'cancel', false)
          write_http_response(client, 400, 'Bad Request', html)
          @oauth_dialog&.execute_script("window.onGoogleOAuthError('⚠️ Login dibatalkan. Silakan coba lagi.')")
          client.close
          stop_oauth_server
          return
        end

        code = params['code']&.first
        if code.nil? || code.empty?
          html = build_callback_html('Kode Tidak Ditemukan', 'Kode OAuth tidak ditemukan. Silakan coba login kembali.', 'error', false)
          write_http_response(client, 400, 'Bad Request', html)
          @oauth_dialog&.execute_script("window.onGoogleOAuthError('❌ Kode OAuth tidak ditemukan.')")
          client.close
          stop_oauth_server
          return
        end

        # Show processing state
        @oauth_dialog&.execute_script("setStatusText('Memproses login...')")

        token_data = exchange_code_for_token(code)
        if token_data['error']
          html = build_callback_html('Token Gagal', "Gagal mendapatkan token: #{token_data['error_description'] || token_data['error']}", 'error', false)
          write_http_response(client, 400, 'Bad Request', html)
          @oauth_dialog&.execute_script("window.onGoogleOAuthError('❌ Gagal mendapatkan token akses.')")
          client.close
          stop_oauth_server
          return
        end

        user_info = fetch_google_user(token_data['access_token'])
        if user_info['error']
          html = build_callback_html('User Info Gagal', 'Gagal mendapatkan informasi pengguna dari Google.', 'error', false)
          write_http_response(client, 400, 'Bad Request', html)
          @oauth_dialog&.execute_script("window.onGoogleOAuthError('❌ Gagal mendapatkan info pengguna.')")
          client.close
          stop_oauth_server
          return
        end

        name = user_info['name'] || user_info['email']
        email = user_info['email']
        photo = user_info['picture']

        on_login_success(name, email, photo)

        html = build_callback_html('Login Berhasil!', "Selamat datang, #{name}! Tab ini akan ditutup otomatis dalam 2 detik.", 'success', true)
        write_http_response(client, 200, 'OK', html)
        @oauth_dialog&.execute_script("window.onGoogleOAuthSuccess('#{escape_js(name)}', '#{escape_js(email)}', '#{escape_js(photo)}')")
        
        client.close
        stop_oauth_server
        
      rescue IO::WaitReadable, Errno::EAGAIN
        # No connection yet, wait for next timer tick
      rescue => e
        puts "[Muko] OAuth server error: #{e.message}"
        puts e.backtrace.join("\n")
        @oauth_dialog&.execute_script("window.onGoogleOAuthError('OAuth error: #{escape_js(e.message)}')")
        stop_oauth_server
      end
    end

    def self.exchange_code_for_token(code)
      uri = URI.parse(GOOGLE_TOKEN_URI)
      response = Net::HTTP.post_form(uri, {
        code: code,
        client_id: GOOGLE_CLIENT_ID,
        client_secret: GOOGLE_CLIENT_SECRET,
        redirect_uri: GOOGLE_REDIRECT_URI,
        grant_type: 'authorization_code'
      })
      JSON.parse(response.body)
    end

    def self.fetch_google_user(access_token)
      uri = URI.parse(GOOGLE_USERINFO_URI)
      request = Net::HTTP::Get.new(uri)
      request['Authorization'] = "Bearer #{access_token}"
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
        http.request(request)
      end
      JSON.parse(response.body)
    end

    def self.write_http_response(client, status_code, status_text, body)
      response = "HTTP/1.1 #{status_code} #{status_text}\r\n"
      response += "Content-Type: text/html; charset=utf-8\r\n"
      response += "Content-Length: #{body.bytesize}\r\n"
      response += "Connection: close\r\n"
      response += "\r\n"
      response += body
      client.write(response)
      client.flush
    end

    def self.build_callback_html(title, message, type, auto_close = false)
      auto_close_script = auto_close ? <<~JS : ''
        <script>
          setTimeout(() => {
            window.close();
            if (!window.closed) {
              document.getElementById('manual-close').style.display = 'block';
            }
          }, 2000);
        </script>
      JS

      <<~HTML
        <!DOCTYPE html>
        <html lang="id">
        <head>
          <meta charset="utf-8">
          <title>Link</title>
          <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body {
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
              background: #ffffff;
              min-height: 100vh;
              display: flex;
              align-items: center;
              justify-content: center;
              padding: 20px;
            }
            .container {
              max-width: 400px;
              width: 100%;
              text-align: center;
            }
            h1 {
              font-size: 28px;
              font-weight: 600;
              color: #000000;
              margin-bottom: 12px;
              line-height: 1.3;
            }
            p {
              font-size: 16px;
              color: #666666;
              line-height: 1.5;
            }
            #manual-close {
              display: none;
              margin-top: 24px;
              padding: 12px 20px;
              background: #f5f5f5;
              border-radius: 8px;
              color: #666666;
              font-size: 14px;
            }
          </style>
        </head>
        <body>
          <div class="container">
            <h1>#{title}</h1>
            <p>#{message}</p>
            <div id="manual-close">
              Tab ini tidak dapat ditutup otomatis. Silakan tutup secara manual.
            </div>
          </div>
          #{auto_close_script}
        </body>
        </html>
      HTML
    end

    def self.escape_js(value)
      value.to_s.gsub('\\', '\\\\').gsub("\n", ' ').gsub("\r", ' ').gsub("'", "\\'")
    end
    
    # Production-ready JSON escaping for execute_script injection
    def self.escape_json_for_js(json_string)
      json_string
        .gsub("\\", "\\\\\\\\")
        .gsub("'", "\\\\'")
        .gsub("\n", "")
        .gsub("\r", "")
    end

    def self.safe_execute(script)
      return unless @dialog
      UI.start_timer(0, false) do
        @dialog.execute_script(script)
      end
    end

    def self.rab_scan_tags(dialog = @cost_dialog)
      model = Sketchup.active_model
      tags = model.layers
      tag_stats = {}
      tag_geometry = {}

      each_entity(model.entities) do |entity|
        next unless entity.respond_to?(:layer)
        tag_name = entity.layer&.name.to_s
        
        # Skip Layer0 (default layer)
        next if tag_name == 'Layer0' || tag_name.empty?
        
        tag_stats[tag_name] ||= 0
        tag_stats[tag_name] += 1

        # Collect geometry info
        tag_geometry[tag_name] ||= { volume: 0.0, area: 0.0, length: 0.0 }
        if entity.respond_to?(:volume)
          tag_geometry[tag_name][:volume] += entity.volume.to_f
        elsif entity.is_a?(Sketchup::Face)
          tag_geometry[tag_name][:area] += entity.area.to_f
        elsif entity.is_a?(Sketchup::Edge)
          tag_geometry[tag_name][:length] += entity.length.to_f
        elsif entity.respond_to?(:definition)
          # For groups/components
          entity.definition.entities.each do |sub|
            if sub.is_a?(Sketchup::Face)
              tag_geometry[tag_name][:area] += sub.area.to_f
            elsif sub.is_a?(Sketchup::Edge)
              tag_geometry[tag_name][:length] += sub.length.to_f
            end
          end
        end
      end

      items = tag_stats.map do |name, count|
        geo = tag_geometry[name] || { volume: 0, area: 0, length: 0 }
        { 
          name: name, 
          count: count,
          volume: geo[:volume],
          area: geo[:area],
          length: geo[:length]
        }
      end

      puts "[Muko] Scanned #{items.length} tags, sending to AI for classification..."
      
      # Send status to UI
      dialog&.execute_script("setStatusText('🤖 AI sedang mengklasifikasi #{items.length} tag...')")
      
      # Send to AI for classification in batches
      begin
        batch_size = 2
        all_classified = []
        
        items.each_slice(batch_size).with_index do |batch, idx|
          puts "[Muko] Processing batch #{idx + 1}/#{(items.length.to_f / batch_size).ceil}"
          dialog&.execute_script("setStatusText('🤖 AI batch #{idx + 1}/#{(items.length.to_f / batch_size).ceil}...')")
          
          begin
            classified_batch = rab_classify_with_ai(batch)
            all_classified.concat(classified_batch)
          rescue => e
            puts "[Muko] Batch #{idx + 1} failed: #{e.message}"
            # Add unclassified batch to result
            all_classified.concat(batch)
          end
          
          # Wait 7 seconds between batches to avoid rate limit
          sleep(7) if idx < (items.length.to_f / batch_size).ceil - 1
        end
        
        puts "[Muko] AI classification done: #{all_classified.length} items"
        payload_json = JSON.generate({ tags: all_classified })
        puts "[Muko] Payload length: #{payload_json.length}"
        puts "[Muko] First tag: #{all_classified.first&.dig(:name) || all_classified.first&.dig('name')}"
        
        # Properly escape JSON for JS injection
        escaped = escape_json_for_js(payload_json)
        puts "[Muko] ✅ JSON escaped, length: #{escaped.length}"
        puts "[Muko] Sending to UI in 0.2s..."
        
        # Wait for dialog to be ready with proper retry mechanism
        send_data_with_retry = lambda do |attempt|
          if attempt > 20
            puts "[Muko] ❌ FAILED: Function not available after 20 attempts (10 seconds)"
            puts "[Muko] This means HTML is not fully loaded or there's a JS error"
            dialog&.execute_script("alert('⚠️ Error: UI not ready. Please close and reopen Muko Cost dialog.')")
            return
          end
          
          fn_exists = dialog&.execute_script("typeof window.onRabScanResult")
          cost_exists = dialog&.execute_script("typeof cost")
          
          puts "[Muko] Attempt #{attempt}: onRabScanResult=#{fn_exists.inspect}, cost=#{cost_exists.inspect}"
          
          if fn_exists == "function" && cost_exists == "object"
            puts "[Muko] ✅ Function ready! Sending data..."
            result = dialog&.execute_script("window.onRabScanResult('#{escaped}')")
            puts "[Muko] Execute result: #{result.inspect}"
            
            if result == true
              puts "[Muko] ✅ Data sent successfully!"
            elsif result == false
              puts "[Muko] ❌ Function returned false - check browser console for errors"
              dialog&.execute_script("console.error('[Muko] onRabScanResult returned false')")
            else
              puts "[Muko] ⚠️ Function executed but returned: #{result.inspect}"
              dialog&.execute_script("console.log('[Muko] Data was sent but result is not true')")
            end
          else
            # Not ready yet, retry in 0.5s
            UI.start_timer(0.5, false) {
              send_data_with_retry.call(attempt + 1)
            }
          end
        end
        
        # Start initial attempt after 1 second to give HTML time to load
        UI.start_timer(1.0, false) {
          send_data_with_retry.call(1)
        }
      rescue => e
        puts "[Muko] AI classification error: #{e.message}"
        puts e.backtrace.first(5)
        # Fallback to manual
        fallback_json = JSON.generate({ tags: items })
        escaped_fallback = escape_json_for_js(fallback_json)
        
        UI.start_timer(0.2, false) {
          dialog&.execute_script("window.onRabScanResult('#{escaped_fallback}')")
          dialog&.execute_script("setStatusText('⚠️ AI gagal, gunakan mapping manual')")
        }
      end
    end

    def self.rab_classify_with_ai(items)
      require 'net/http'
      require 'json'
      require 'uri'

      puts "[Muko] AI classify started for #{items.length} items"
      
      # Build prompt
      items_desc = items.map do |item|
        "Tag: #{item[:name]}, Entities: #{item[:count]}, Volume: #{item[:volume].round(2)} m³, Area: #{item[:area].round(2)} m², Length: #{item[:length].round(2)} m"
      end.join("\n")

      # Simplify: only send tag names, not geometry
      tag_names = items.map { |item| item[:name] }.join(", ")
      
      prompt = <<~PROMPT
        Classify construction tags: #{tag_names}
        
        Rules:
        SLOOF/Sloof/PONDASI→Pondasi, KOLOM→Kolom, BALOK/RING→Balok, DEK/LANTAI ATAS→Dek, DINDING/WALL→Dinding, ATAP→Atap, TANGGA→Tangga, RAILING→Railing
        
        Materials:
        Pondasi/Kolom/Balok/Dek/Tangga→Semen,Pasir,Besi,Agregat
        Dinding→Bata Merah,Semen,Pasir
        Atap→Genteng,Rangka Baja Ringan
        Railing→Besi,Cat
        
        Return JSON only:
        [{"tag_name":"SLOOF","category":"Pondasi","materials":[{"name":"Semen","unit":"sak"},{"name":"Pasir","unit":"m3"},{"name":"Besi","unit":"kg"},{"name":"Agregat","unit":"m3"}]}]
      PROMPT

      puts "[Muko] Calling Groq API..."
      
      uri = URI(GROQ_ENDPOINT)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 60
      http.open_timeout = 10

      request = Net::HTTP::Post.new(uri.path, {
        'Content-Type' => 'application/json',
        'Authorization' => "Bearer #{GROQ_API_KEY}"
      })

      request.body = {
        model: GROQ_MODEL,
        messages: [
          {
            role: "system",
            content: "You are a strict JSON generator. Respond ONLY with valid JSON array. No explanation. No markdown. Ensure JSON is complete and properly closed."
          },
          {
            role: "user",
            content: prompt
          }
        ],
        temperature: 0,
        max_tokens: 2000,
        response_format: { type: "json_object" }
      }.to_json

      puts "[Muko] Request body size: #{request.body.length} bytes"
      
      result = call_groq_with_retry(request, http)
      
      puts "[Muko] Response code: 200"
      
      content = result.dig('choices', 0, 'message', 'content').to_s.strip
      puts "[Muko] AI response length: #{content.length}"
      
      begin
        parsed = JSON.parse(content)
        # Groq json_object mode might wrap in {"items": [...]} or {"tags": [...]}
        classified_items = parsed.is_a?(Array) ? parsed : (parsed['items'] || parsed['tags'] || [])
      rescue JSON::ParserError => e
        puts "[Muko] JSON parse failed: #{e.message}"
        puts "[Muko] Content: #{content[0..500]}"
        raise
      end
      
      puts "[Muko] Parsed #{classified_items.length} classified items"
      
      # Merge with original scan data and calculate material qty
      result_items = items.map do |item|
        ai_result = classified_items.find { |c| c['tag_name'] == item[:name] }
        
        # Fallback category detection if AI failed
        category = ai_result&.dig('category')
        if category.nil? || category.empty? || category == 'Lainnya'
          tag_lower = item[:name].to_s.downcase
          category = if tag_lower.include?('sloof') || tag_lower.include?('pondasi')
            'Pondasi'
          elsif tag_lower.include?('kolom')
            'Kolom'
          elsif tag_lower.include?('balok') || tag_lower.include?('ring')
            'Balok'
          elsif tag_lower.include?('dek') || tag_lower.include?('lantai atas')
            'Dek'
          elsif tag_lower.include?('dinding') || tag_lower.include?('wall')
            'Dinding'
          elsif tag_lower.include?('atap') || tag_lower.include?('roof')
            'Atap'
          elsif tag_lower.include?('tangga')
            'Tangga'
          elsif tag_lower.include?('railing')
            'Railing'
          elsif tag_lower.include?('plafon') || tag_lower.include?('ceiling')
            'Plafon'
          elsif tag_lower.include?('lantai') || tag_lower.include?('floor')
            'Lantai'
          else
            'Lainnya'
          end
        end
        
        # Override method based on category FIRST (more reliable than geometry)
        category_normalized = category.to_s.downcase
        is_beton = category_normalized.include?('pondasi') || 
                   category_normalized.include?('kolom') || 
                   category_normalized.include?('balok') || 
                   category_normalized.include?('sloof') || 
                   category_normalized.include?('ringbalk') ||
                   category_normalized.include?('dek') ||
                   category_normalized.include?('struktur') ||
                   category_normalized.include?('beton')
        
        if is_beton
          method = 'volume' # Struktur beton always volume
        elsif category_normalized.include?('atap') || category_normalized.include?('roof')
          method = 'area' # Atap always area
        elsif category_normalized.include?('dinding') || category_normalized.include?('wall')
          method = 'area' # Dinding always area
        elsif category_normalized.include?('lantai') || category_normalized.include?('floor')
          method = 'area' # Lantai always area
        elsif category_normalized.include?('plafon') || category_normalized.include?('ceiling')
          method = 'area' # Plafon always area
        else
          # Fallback: auto-detect from geometry
          method = if item[:volume] > 0.1
            'volume'
          elsif item[:area] > 0.1
            'area'
          elsif item[:length] > 0.1
            'length'
          else
            'count'
          end
        end
        
        unit = case method
        when 'volume' then 'm3'
        when 'area' then 'm2'
        when 'length' then 'm'
        else 'unit'
        end
        
        # Determine qty_base from geometry
        qty_base = case method
        when 'volume'
          item[:volume]
        when 'area'
          item[:area]
        when 'length'
          item[:length]
        else
          item[:count] || 0
        end
        
        # Skip if qty_base invalid
        next if qty_base.nil? || qty_base <= 0
        
        # Get materials from AI or fallback
        material_list = ai_result&.dig('materials') || []
        
        # Fallback materials if AI didn't provide
        if material_list.empty?
          material_list = case category
          when 'Pondasi', 'Kolom', 'Balok', 'Dek', 'Tangga'
            [
              {'name' => 'Semen', 'unit' => 'sak'},
              {'name' => 'Pasir', 'unit' => 'm3'},
              {'name' => 'Besi', 'unit' => 'kg'},
              {'name' => 'Agregat', 'unit' => 'm3'}
            ]
          when 'Dinding'
            [
              {'name' => 'Bata Merah', 'unit' => 'buah'},
              {'name' => 'Semen', 'unit' => 'kg'},
              {'name' => 'Pasir', 'unit' => 'm3'}
            ]
          when 'Atap'
            [
              {'name' => 'Genteng', 'unit' => 'buah'},
              {'name' => 'Rangka Baja Ringan', 'unit' => 'kg'}
            ]
          when 'Railing'
            [
              {'name' => 'Besi', 'unit' => 'kg'},
              {'name' => 'Cat', 'unit' => 'kaleng'}
            ]
          when 'Lantai'
            [
              {'name' => 'Keramik', 'unit' => 'm2'},
              {'name' => 'Semen', 'unit' => 'kg'},
              {'name' => 'Pasir', 'unit' => 'm3'}
            ]
          when 'Plafon'
            [
              {'name' => 'Gypsum Board', 'unit' => 'lembar'},
              {'name' => 'Rangka Hollow', 'unit' => 'm'}
            ]
          else
            []
          end
        end
        
        # Get materials from AI and calculate qty
        materials = material_list.map do |mat|
          calculated_qty = calculate_material_qty(
            mat['name'],
            qty_base,
            category,
            method
          )
          
          {
            'name' => mat['name'],
            'qty' => calculated_qty,
            'unit' => mat['unit'] || 'unit',
            'unit_price' => 0
          }
        end
        
        merged = item.merge(
          category: category,
          method: method,
          unit: unit,
          waste_percent: ai_result&.dig('waste_percent') || 10,
          qty_base: qty_base,
          materials: materials
        )
        puts "[Muko] Tag #{item[:name]}: #{merged[:materials]&.length || 0} materials, qty_base: #{qty_base.round(2)}"
        merged
      end
      
      puts "[Muko] AI classification complete"
      result_items
    rescue JSON::ParserError => e
      puts "[Muko] JSON Parse error - using fallback classification"
      items
    rescue => e
      puts "[Muko] JSON Parse error - AI response incomplete or invalid"
      puts "[Muko] Attempting partial parse..."
      
      # Try to salvage partial data
      partial_items = []
      begin
        # Try to fix incomplete JSON by adding closing brackets
        fixed_content = content.dup
        # Count opening and closing braces
        open_braces = fixed_content.count('{')
        close_braces = fixed_content.count('}')
        open_brackets = fixed_content.count('[')
        close_brackets = fixed_content.count(']')
        
        # Add missing closing braces/brackets
        (open_braces - close_braces).times { fixed_content << "\n}" }
        (open_brackets - close_brackets).times { fixed_content << "\n]" }
        
        partial_items = JSON.parse(fixed_content)
        puts "[Muko] Partial parse successful: #{partial_items.length} items recovered"
      rescue
        puts "[Muko] Partial parse failed, returning items without AI classification"
      end
      
      # Merge partial AI data if available
      if partial_items.any?
        items.map do |item|
          ai_result = partial_items.find { |c| c['tag_name'] == item[:name] }
          if ai_result
            item.merge(
              category: ai_result['category'] || 'Lainnya',
              method: ai_result['method'] || 'count',
              unit: ai_result['unit'] || 'unit',
              waste_percent: ai_result['waste_percent'] || 0,
              qty_base: ai_result['qty_base'] || item[:volume] || item[:area] || 0,
              materials: ai_result['materials'] || []
            )
          else
            item
          end
        end
      else
        items # Return original if all failed
      end
    end
    
    def self.call_groq_with_retry(request, http, retries = 2)
      attempts = 0
      begin
        attempts += 1
        response = http.request(request)
        raise "API error #{response.code}: #{response.body}" unless response.code.to_i == 200
        JSON.parse(response.body)
      rescue => e
        puts "[Muko] Attempt #{attempts} failed: #{e.message}"
        retry if attempts <= retries
        raise
      end
    end

    def self.rab_compute_qty(items_json, dialog = @cost_dialog)
      items = JSON.parse(items_json || '[]')
      qty = {}
      model = Sketchup.active_model

      items.each do |item|
        tag_name = item['tag_name']
        method = item['method'] || 'count'
        qty[tag_name] = compute_tag_qty(model, tag_name, method)
      end

      qty_json = JSON.generate({ qty: qty })
      escaped_qty = escape_json_for_js(qty_json)
      dialog&.execute_script("window.onRabQtyResult('#{escaped_qty}')")
    rescue => e
      puts "[Muko] RAB compute error: #{e.message}"
      dialog&.execute_script("setStatusText('❌ Gagal hitung qty: #{escape_js(e.message)}')")
    end

    def self.rab_save_state(state_json, dialog = @cost_dialog)
      state = JSON.parse(state_json || '{}')
      model = Sketchup.active_model
      dict = model.attribute_dictionary(RAB_DICT_NAME, true)
      dict[RAB_STATE_KEY] = state.to_json
      puts "[Muko] RAB state saved: #{state['items']&.length || 0} items"
      dialog&.execute_script("setStatusText('✅ RAB disimpan ke model')")
    rescue => e
      puts "[Muko] RAB save error: #{e.message}"
      dialog&.execute_script("setStatusText('❌ Gagal simpan: #{escape_js(e.message)}')")
    end

    def self.rab_load_state(dialog = @cost_dialog)
      state = rab_load_state_hash
      state_json = JSON.generate(state)
      escaped_state = escape_json_for_js(state_json)
      dialog&.execute_script("window.onRabStateLoaded('#{escaped_state}')")
    end

    def self.rab_load_state_hash
      model = Sketchup.active_model
      dict = model.attribute_dictionary(RAB_DICT_NAME, false)
      return { 'items' => [], 'settings' => {} } unless dict && dict[RAB_STATE_KEY]

      JSON.parse(dict[RAB_STATE_KEY])
    rescue
      { 'items' => [], 'settings' => {} }
    end

    def self.rab_export_csv(payload_json, dialog = @cost_dialog)
      payload = JSON.parse(payload_json || '{}')
      rows = payload['rows'] || []
      csv_content = "Kategori,Tag,Qty,Unit,Harga,Subtotal\n"
      rows.each do |row|
        csv_content << row.map { |cell| cell.to_s }.map { |cell| cell.to_s.include?(',') ? '"' + cell.to_s.gsub('"', '""') + '"' : cell.to_s }.join(',') + "\n"
      end

      bom = "\uFEFF"
      csv_with_bom = bom + csv_content

      default_name = "muko_rab_#{Time.now.strftime('%Y%m%d_%H%M%S')}.csv"
      save_path = UI.savepanel("Simpan RAB CSV", nil, default_name)
      return unless save_path

      File.write(save_path, csv_with_bom)
      dialog&.execute_script("setStatusText('✅ CSV disimpan: #{escape_js(File.basename(save_path))}')")
    rescue => e
      dialog&.execute_script("setStatusText('❌ Gagal export CSV: #{escape_js(e.message)}')")
    end

    def self.rab_highlight_unknown(mode, items_json)
      if mode == 'off'
        clear_rab_highlight
        return
      end

      items = JSON.parse(items_json || '[]')
      model = Sketchup.active_model
      @rab_highlight_store ||= { entities: {}, hidden: [] }
      unknown_entities = []
      tagged_entities = []

      each_entity(model.entities) do |entity|
        next unless entity.respond_to?(:layer)
        tag_name = entity.layer&.name.to_s
        
        # Untagged = Layer0, nil, empty, or "Untagged"
        if tag_name.nil? || tag_name.empty? || tag_name == 'Layer0' || tag_name == 'Untagged'
          unknown_entities << entity
        else
          tagged_entities << entity
        end
      end

      # Mark untagged red + hide tagged
      highlight_and_hide(unknown_entities, tagged_entities)
      puts "[Muko] Highlighted #{unknown_entities.length} untagged, hidden #{tagged_entities.length} tagged"
    rescue => e
      puts "[Muko] Highlight error: #{e.message}"
    end

    def self.highlight_and_hide(untagged, tagged)
      clear_rab_highlight
      model = Sketchup.active_model
      
      # Create red material for untagged
      red_material = model.materials['Muko_RAB_Highlight']
      unless red_material
        red_material = model.materials.add('Muko_RAB_Highlight')
        red_material.color = Sketchup::Color.new(255, 0, 0)
        red_material.alpha = 0.5
      end

      # Mark untagged red
      untagged.each do |entity|
        next unless entity.respond_to?(:material)
        @rab_highlight_store[:entities][entity.persistent_id] = {
          material: entity.material,
          back_material: entity.respond_to?(:back_material) ? entity.back_material : nil
        }
        entity.material = red_material
        if entity.respond_to?(:back_material)
          entity.back_material = red_material
        end
      end
      
      # Hide tagged entities
      tagged.each do |entity|
        next unless entity.respond_to?(:hidden=)
        @rab_highlight_store[:hidden] << entity.persistent_id unless entity.hidden?
        entity.hidden = true
      end
      
      model.active_view.invalidate
    end

    def self.clear_rab_highlight
      return unless @rab_highlight_store
      model = Sketchup.active_model
      all_entities = []
      each_entity(model.entities) { |e| all_entities << e }
      entity_by_id = all_entities.map { |e| [e.persistent_id, e] }.to_h
      
      # Restore materials
      (@rab_highlight_store[:entities] || {}).each do |pid, data|
        entity = entity_by_id[pid]
        next unless entity
        entity.material = data[:material] if entity.respond_to?(:material)
        if entity.respond_to?(:back_material)
          entity.back_material = data[:back_material]
        end
      end
      
      # Unhide entities
      (@rab_highlight_store[:hidden] || []).each do |pid|
        entity = entity_by_id[pid]
        entity.hidden = false if entity && entity.respond_to?(:hidden=)
      end
      
      @rab_highlight_store = { entities: {}, hidden: [] }
      model.active_view.invalidate
    end

    def self.compute_tag_qty(model, tag_name, method)
      entities = []
      each_entity(model.entities) do |entity|
        next unless entity.respond_to?(:layer)
        entities << entity if entity.layer&.name.to_s == tag_name
      end
      case method
      when 'volume'
        sum_volume(entities)
      when 'area'
        sum_area(entities)
      when 'length'
        sum_length(entities)
      else
        entities.length.to_f
      end
    end

    def self.sum_volume(entities)
      entities.sum do |entity|
        if entity.respond_to?(:volume)
          entity.volume.to_f
        elsif entity.respond_to?(:definition)
          entity.definition.entities.sum { |e| e.respond_to?(:volume) ? e.volume.to_f : 0.0 }
        else
          0.0
        end
      end
    end

    def self.sum_area(entities)
      entities.sum do |entity|
        if entity.is_a?(Sketchup::Face)
          entity.area.to_f
        elsif entity.respond_to?(:definition)
          entity.definition.entities.grep(Sketchup::Face).sum { |f| f.area.to_f }
        else
          0.0
        end
      end
    end

    def self.sum_length(entities)
      entities.sum do |entity|
        if entity.is_a?(Sketchup::Edge)
          entity.length.to_f
        elsif entity.respond_to?(:definition)
          entity.definition.entities.grep(Sketchup::Edge).sum { |e| e.length.to_f }
        else
          0.0
        end
      end
    end
    
    def self.calculate_material_qty(material_name, qty_base, category, method)
      return 0 if qty_base.nil? || qty_base <= 0
      
      # Normalize category
      category_normalized = category.to_s.downcase
      is_beton = category_normalized.include?('pondasi') || 
                 category_normalized.include?('kolom') || 
                 category_normalized.include?('balok') || 
                 category_normalized.include?('sloof') || 
                 category_normalized.include?('ringbalk') ||
                 category_normalized.include?('dek') ||
                 category_normalized.include?('struktur') ||
                 category_normalized.include?('beton')
      
      is_dinding = category_normalized.include?('dinding') || category_normalized.include?('wall')
      is_atap = category_normalized.include?('atap') || category_normalized.include?('roof')
      is_lantai = category_normalized.include?('lantai') || category_normalized.include?('floor')
      is_plafon = category_normalized.include?('plafon') || category_normalized.include?('ceiling')
      
      # Convert to m3/m2 from internal units (inches)
      qty_metric = case method
      when 'volume'
        qty_base / (39.3701 ** 3) # cubic inches to m3
      when 'area'
        qty_base / (39.3701 ** 2) # square inches to m2
      when 'length'
        qty_base / 39.3701 # inches to m
      else
        qty_base
      end
      
      puts "[Muko] Calc: #{material_name}, cat: #{category}, method: #{method}, qty_base: #{qty_base.round(2)}, qty_metric: #{qty_metric.round(4)}"
      
      case material_name
      # Struktur Beton (per m3)
      when 'Semen'
        if is_beton
          qty_metric * 7 # 7 sak per m3
        elsif is_dinding
          qty_metric * 11 # 11 kg per m2
        elsif is_lantai
          qty_metric * 5 # 5 kg per m2
        else
          0
        end
      
      when 'Pasir'
        if is_beton
          qty_metric * 0.5 # 0.5 m3 per m3
        elsif is_dinding
          qty_metric * 0.043 # 0.043 m3 per m2
        elsif is_lantai
          qty_metric * 0.025 # 0.025 m3 per m2
        else
          0
        end
      
      when 'Besi'
        if is_beton
          qty_metric * 80 # 80 kg per m3
        else
          0
        end
      
      when 'Agregat'
        if is_beton
          qty_metric * 0.7 # 0.7 m3 per m3
        else
          0
        end
      
      when 'Bata Merah', 'Bata'
        if is_dinding
          qty_metric * 70 # 70 buah per m2
        else
          0
        end
      
      when 'Genteng'
        if is_atap
          qty_metric * 25 # 25 buah per m2
        else
          0
        end
      
      when 'Rangka Baja Ringan'
        if is_atap
          qty_metric * 4 # 4 kg per m2
        else
          0
        end
      
      when 'Keramik'
        if is_lantai
          qty_metric * 1 # 1 m2 per m2
        else
          0
        end
      
      when 'Gypsum Board', 'Gypsum'
        if is_plafon
          qty_metric * 1 # 1 lembar per m2
        else
          0
        end
      
      when 'Rangka Hollow'
        if is_plafon
          qty_metric * 3 # 3 m per m2
        else
          0
        end
      
      else
        0
      end
    end
    
    def self.rab_update_prices(items_json, dialog = @cost_dialog)
      items = JSON.parse(items_json || '[]')
      
      puts "[Muko] Updating prices for #{items.length} items..."
      
      # Build material list
      all_materials = []
      items.each do |item|
        next unless item['materials']
        item['materials'].each do |mat|
          all_materials << {
            category: item['category'],
            name: mat['name'],
            unit: mat['unit']
          }
        end
      end
      
      if all_materials.empty?
        dialog&.execute_script("setStatusText('⚠️ Tidak ada material untuk diupdate')")
        return
      end
      
      # Call AI for price estimation
      updated_items = rab_estimate_prices_with_ai(items, all_materials)
      
      price_json = JSON.generate({ items: updated_items })
      escaped_price = escape_json_for_js(price_json)
      dialog&.execute_script("window.onRabPriceUpdate('#{escaped_price}')")
    rescue => e
      puts "[Muko] Price update error: #{e.message}"
      dialog&.execute_script("setStatusText('❌ Gagal update harga: #{escape_js(e.message)}')")
    end
    
    def self.rab_estimate_prices_with_ai(items, materials)
      require 'net/http'
      require 'json'
      require 'uri'
      
      puts "[Muko] AI price estimation started for #{materials.length} materials"
      
      materials_desc = materials.uniq { |m| "#{m[:category]}-#{m[:name]}" }.map do |mat|
        "#{mat[:category]} - #{mat[:name]} (#{mat[:unit]})"
      end.join("\n")
      
      prompt = <<~PROMPT
        Anda adalah asisten RAB konstruksi Indonesia. Estimasi harga pasar material konstruksi berikut (harga per #{Time.now.strftime('%B %Y')}):
        
        Material:
        #{materials_desc}
        
        Berikan harga pasar rata-rata di Indonesia (Jakarta/kota besar) dalam Rupiah.
        Pertimbangkan:
        - Harga eceran/retail (bukan grosir)
        - Kualitas standar/medium
        - Termasuk PPN jika applicable
        
        Return HANYA valid JSON array:
        [
          {"category": "Pondasi", "name": "Semen", "unit": "sak", "unit_price": 65000},
          {"category": "Pondasi", "name": "Pasir", "unit": "m3", "unit_price": 250000}
        ]
      PROMPT
      
      puts "[Muko] Calling Groq API for price estimation..."
      
      uri = URI(GROQ_ENDPOINT)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 60
      
      request = Net::HTTP::Post.new(uri.path, {
        'Content-Type' => 'application/json',
        'Authorization' => "Bearer #{GROQ_API_KEY}"
      })
      
      request.body = {
        model: GROQ_MODEL,
        messages: [
          {
            role: "system",
            content: "You are a strict JSON generator. Respond ONLY with valid JSON array. No explanation. No markdown."
          },
          {
            role: "user",
            content: prompt
          }
        ],
        temperature: 0,
        max_tokens: 2000,
        response_format: { type: "json_object" }
      }.to_json
      
      response = http.request(request)
      
      if response.code.to_i != 200
        puts "[Muko] Response body: #{response.body}"
        raise "API error: #{response.code}"
      end
      
      result = JSON.parse(response.body)
      content = result.dig('choices', 0, 'message', 'content').to_s
      
      # Extract JSON
      json_start = content.index('[')
      json_end = content.rindex(']')
      
      if json_start && json_end
        content = content[json_start..json_end]
      end
      
      price_list = JSON.parse(content)
      
      puts "[Muko] Received #{price_list.length} price estimates"
      
      # Apply prices to items
      items.each do |item|
        next unless item['materials']
        item['materials'].each do |mat|
          price_data = price_list.find { |p| p['category'] == item['category'] && p['name'] == mat['name'] }
          mat['unit_price'] = price_data['unit_price'] if price_data
        end
      end
      
      puts "[Muko] Price update complete"
      items
    rescue => e
      puts "[Muko] AI price API error: #{e.class} - #{e.message}"
      puts e.backtrace.first(10)
      items # Return original if failed
    end

    # ComfyUI Integration Methods - Async Version
    def self.upload_and_queue(image_path)
      require 'base64'
      
      render_start = Time.now
      puts "[Muko] ===== MODAL RENDER START ====="
      
      FileUtils.mkdir_p(RENDERS_DIR) unless File.directory?(RENDERS_DIR)
      
      # Upload image to ComfyUI
      step_start = Time.now
      safe_execute("setStatusText('📤 Uploading to ComfyUI...')")
      
      upload_uri = URI("#{COMFYUI_URL}/upload/image")
      filename = File.basename(image_path)
      boundary = "----MukoBoundary#{Time.now.to_i}"
      
      # Build multipart body manually
      file_content = File.binread(image_path)
      body = ""
      body << "--#{boundary}\r\n"
      body << "Content-Disposition: form-data; name=\"image\"; filename=\"#{filename}\"\r\n"
      body << "Content-Type: image/png\r\n\r\n"
      body << file_content
      body << "\r\n--#{boundary}\r\n"
      body << "Content-Disposition: form-data; name=\"overwrite\"\r\n\r\n"
      body << "true\r\n"
      body << "--#{boundary}--\r\n"
      
      upload_request = Net::HTTP::Post.new(upload_uri.path)
      upload_request.body = body
      upload_request['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
      upload_request['Content-Length'] = body.bytesize.to_s
      
      upload_response = Net::HTTP.start(upload_uri.hostname, upload_uri.port) do |http|
        http.request(upload_request)
      end
      
      if upload_response.code != '200'
        raise "Upload failed: #{upload_response.code} - #{upload_response.body}"
      end
      
      upload_result = JSON.parse(upload_response.body)
      uploaded_filename = upload_result['name'] || filename
      puts "[Muko] ✓ Upload took #{(Time.now - step_start).round(2)}s - filename: #{uploaded_filename}"
      
      # Load workflow and inject uploaded image
      step_start = Time.now
      safe_execute("setStatusText('⚙️ Preparing workflow...')")
      
      unless File.exist?(WORKFLOW_FILE)
        raise "Workflow file not found: #{WORKFLOW_FILE}"
      end
      
      workflow = JSON.parse(File.read(WORKFLOW_FILE))
      puts "[Muko] Workflow loaded, keys: #{workflow.keys.inspect}"

      load_image_node_id = workflow.find { |_id, node| node['class_type'] == 'LoadImage' }&.first
      load_image_node_id ||= '1' if workflow['1']
      load_image_node_id ||= '10' if workflow['10']

      unless load_image_node_id && workflow[load_image_node_id]
        raise "LoadImage node not found in workflow. Available nodes: #{workflow.keys.join(', ')}"
      end

      workflow[load_image_node_id]['inputs']['image'] = uploaded_filename
      puts "[Muko] ✓ Workflow prep took #{(Time.now - step_start).round(2)}s (node #{load_image_node_id})"
      
      # Queue prompt
      step_start = Time.now
      safe_execute("setStatusText('🎨 Rendering (30 steps)...')")
      
      prompt_uri = URI("#{COMFYUI_URL}/prompt")
      prompt_request = Net::HTTP::Post.new(prompt_uri)
      prompt_request['Content-Type'] = 'application/json'
      prompt_request.body = { prompt: workflow }.to_json
      
      prompt_response = Net::HTTP.start(prompt_uri.hostname, prompt_uri.port) do |http|
        http.request(prompt_request)
      end
      
      puts "[Muko] Prompt response code: #{prompt_response.code}"
      puts "[Muko] Prompt response body: #{prompt_response.body[0..500]}"  # First 500 chars
      
      if prompt_response.code != '200'
        puts "[Muko] ComfyUI error response: #{prompt_response.body}"
        raise "Prompt queue failed: #{prompt_response.code} - #{prompt_response.body}"
      end
      
      prompt_result = JSON.parse(prompt_response.body)
      prompt_id = prompt_result['prompt_id']
      puts "[Muko] ✓ Queued prompt #{prompt_id} (#{(Time.now - step_start).round(2)}s)"
      
      if prompt_result['error']
        puts "[Muko] ⚠️ Prompt has error: #{prompt_result['error']}"
      end
      
      prompt_id  # Return prompt_id for async polling
    end
    
    def self.check_render_status
      puts "[Muko] === Polling tick (prompt_id: #{@render_prompt_id.inspect}) ==="
      return unless @render_prompt_id
      
      @render_poll_count ||= 0
      @render_poll_count += 1
      elapsed = Time.now - @render_start_time
      
      puts "[Muko] Polling ##{@render_poll_count}, elapsed: #{elapsed.round}s"
      
      # Jangan menimpa teks jika menggunakan websocket persentase dari browser
      # safe_execute("setStatusText('🎨 Rendering... (#{elapsed.round}s)')")
      
      begin
        history_uri = URI("#{COMFYUI_URL}/history/#{@render_prompt_id}")
        history_response = Net::HTTP.get_response(history_uri)
        
        puts "[Muko] History response code: #{history_response.code}"
        
        if history_response.code == '200'
          history = JSON.parse(history_response.body)
          puts "[Muko] History keys: #{history.keys.inspect}"
          puts "[Muko] Has prompt_id? #{history[@render_prompt_id] ? 'YES' : 'NO'}"
          
          if history[@render_prompt_id]
            puts "[Muko] Prompt data: #{history[@render_prompt_id].keys.inspect}"
            puts "[Muko] Status: #{history[@render_prompt_id]['status'].inspect}"
            puts "[Muko] Outputs: #{history[@render_prompt_id]['outputs'].inspect}"
          end
          
          if history[@render_prompt_id] && history[@render_prompt_id]['outputs']
            outputs = history[@render_prompt_id]['outputs']
            puts "[Muko] Outputs is empty? #{outputs.empty?}"
            
            outputs.each do |node_id, output_data|
              if output_data['images']
                filename = output_data['images'][0]['filename']
                puts "[Muko] ✓ Render complete, downloading: #{filename}"
                download_render_result(filename)
                stop_render_polling
                return
              end
            end
          end
        end
      rescue => e
        puts "[Muko] Polling error: #{e.message}"
      end
      
      # Timeout after 15 minutes (900 detik)
      if elapsed > 900
        safe_execute("stopMatrixAnimation()")
        safe_execute("setStatusText('️ Render timeout')")
        stop_render_polling
      end
    end
    
    def self.download_render_result(filename)
      begin
        view_uri = URI("#{COMFYUI_URL}/view?filename=#{filename}")
        output_image_data = Net::HTTP.get(view_uri)
        
        timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
        result_path = File.join(RENDERS_DIR, "muko_#{timestamp}.png")
        File.open(result_path, 'wb') { |f| f.write(output_image_data) }
        
        # Update UI
        @last_result = result_path
        escaped_result = result_path.gsub('\\', '/')
        escaped_before = @last_capture.gsub('\\', '/')
        safe_execute("stopMatrixAnimation()")
        safe_execute("setBeforeAfter('file:///#{escaped_before}', 'file:///#{escaped_result}')")
        safe_execute("setStatusText('✅ Render complete!')")
        
        total_duration = Time.now - @render_start_time
        puts "[Muko] ===== RENDER COMPLETE (#{total_duration.round(2)}s total) ====="
      rescue => e
        puts "[Muko] Download error: #{e.message}"
        safe_execute("stopMatrixAnimation()")
        safe_execute("setStatusText('❌ Download failed: #{escape_js(e.message)}')")
        stop_render_polling
      end
    end
    
    def self.start_render_polling
      puts "[Muko] Starting polling timer (3s interval)..."
      @render_timer = UI.start_timer(3, true) do
        check_render_status
      end
      puts "[Muko] Polling timer started: #{@render_timer.inspect}"
    end
    
    def self.stop_render_polling
      UI.stop_timer(@render_timer) if @render_timer
      @render_timer = nil
      @render_prompt_id = nil
      @render_in_progress = false
    end

    def self.build_command(name, tooltip, icons = nil, &block)
      cmd = UI::Command.new(name) { block.call if block }
      cmd.tooltip = tooltip
      cmd.status_bar_text = tooltip
      if icons
        cmd.small_icon = icons[:small]
        cmd.large_icon = icons[:large]
      end
      cmd
    end

    def self.open_cost_panel
      unless @cost_dialog
        @cost_dialog = UI::HtmlDialog.new(
          dialog_title: "Muko Cost (RAB)",
          preferences_key: "MukoCost",
          scrollable: true,
          resizable: false,
          width: 920,
          height: 720,
          style: UI::HtmlDialog::STYLE_DIALOG
        )
        
        @cost_dialog_ready = false
        setup_cost_dialog_callbacks(@cost_dialog)
        @cost_dialog.set_file(UI_FILE)
      end
      
      @cost_dialog.show
      # No need to manually call muko.openCost() - JavaScript will auto-open on DOMContentLoaded
    end
    
    def self.setup_cost_dialog_callbacks(dialog)
      dialog.add_action_callback("rab_scan_tags") { |_ctx|
        rab_scan_tags(dialog)
      }

      dialog.add_action_callback("rab_compute_qty") { |_ctx, items_json|
        rab_compute_qty(items_json, dialog)
      }

      dialog.add_action_callback("rab_save_state") { |_ctx, state_json|
        rab_save_state(state_json, dialog)
      }

      dialog.add_action_callback("rab_load_state") { |_ctx|
        rab_load_state(dialog)
      }

      dialog.add_action_callback("rab_export_csv") { |_ctx, payload_json|
        rab_export_csv(payload_json, dialog)
      }

      dialog.add_action_callback("rab_highlight_unknown") { |_ctx, mode, items_json|
        rab_highlight_unknown(mode, items_json)
      }
      
      dialog.add_action_callback("rab_update_prices") { |_ctx, items_json|
        rab_update_prices(items_json, dialog)
      }
      
      dialog.add_action_callback("login_guest") { |_ctx|
        guest_login(dialog)
      }
      
      dialog.add_action_callback("load_saved_session") { |_ctx|
        load_saved_session(dialog)
      }
      
      dialog.add_action_callback("cost_dialog_ready") { |_ctx|
        puts "[Muko] ✅ Cost dialog HTML fully loaded!"
        @cost_dialog_ready = true
      }
    end

    def self.each_entity(entities, &block)
      entities.each do |entity|
        yield entity
        if entity.respond_to?(:entities)
          each_entity(entity.entities, &block)
        elsif entity.respond_to?(:definition)
          each_entity(entity.definition.entities, &block)
        end
      end
    end

    unless file_loaded?(__FILE__)
      ensure_assets_dir
      ensure_ui_dir

      toolbar = UI::Toolbar.new(EXTENSION_NAME)

      # Button 1: Muko AI
      cmd_muko_ai = build_command(
        "Muko AI",
        "Buka Muko AI",
        {
          small: File.join(ASSETS_DIR, "muko.png"),
          large: File.join(ASSETS_DIR, "muko.png")
        }
      ) { open_dialog }

      # Button 2: Cost (RAB)
      cmd_cost = build_command(
        "Muko Cost",
        "Buka Cost (RAB)",
        {
          small: File.join(ASSETS_DIR, "cost.png"),
          large: File.join(ASSETS_DIR, "cost.png")
        }
      ) { open_cost_panel }

      toolbar.add_item(cmd_muko_ai)
      toolbar.add_item(cmd_cost)
      toolbar.show

      UI.menu("Extensions").add_item(EXTENSION_NAME) { open_dialog }
      UI.menu("Extensions").add_item("Muko Cost (RAB)") { open_cost_panel }

      file_loaded(__FILE__)
    end
  end
end
