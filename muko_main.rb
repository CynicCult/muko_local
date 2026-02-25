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

    AUTH_DATA_FILE = File.join(UI_DIR, "user_session.json")

    # Panggil fungsi ini saat open_dialog pertama kali dijalankan
    def self.load_saved_session
      if File.exist?(AUTH_DATA_FILE)
        begin
          data = JSON.parse(File.read(AUTH_DATA_FILE))
          # Kirim data ke UI jika session masih valid
          safe_execute("window.onGoogleOAuthSuccess('#{escape_js(data['name'])}', '#{escape_js(data['email'])}', '#{escape_js(data['photo'])}')")
        rescue
          File.delete(AUTH_DATA_FILE)
        end
      end
    end

    # Modifikasi callback sukses login Anda
    def self.on_login_success(name, email, photo)
      session_data = { name: name, email: email, photo: photo, login_time: Time.now.to_i }
      File.write(AUTH_DATA_FILE, session_data.to_json)
      # ... jalankan script sukses UI ...
    end

    # Modifikasi callback sukses login Anda
    def self.on_login_success(name, email, photo)
      session_data = { name: name, email: email, photo: photo, login_time: Time.now.to_i }
      File.write(AUTH_DATA_FILE, session_data.to_json)
      # ... jalankan script sukses UI ...
    end

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
      @dialog ||= UI::HtmlDialog.new(
        dialog_title: EXTENSION_NAME,
        preferences_key: "MukoAI",
        scrollable: true,
        resizable: false,
        width: 468,
        height: 720,
        style: UI::HtmlDialog::STYLE_DIALOG
      )

      @dialog.set_file(UI_FILE)

      @dialog.add_action_callback("open_link") { |_ctx|
        UI.openURL("https://link.com")
      }

      @dialog.add_action_callback("login_google") { |_ctx|
        @dialog.execute_script("setStatusText('Membuka login Google...')")
        start_google_oauth
      }

      @dialog.add_action_callback("start_google_oauth") { |_ctx|
        @dialog.execute_script("setStatusText('Membuka login Google...')")
        start_google_oauth
      }

      @dialog.add_action_callback("login_guest") { |_ctx|
        @dialog.execute_script("setStatusText('Guest mode')")
      }

      @dialog.add_action_callback("capture_scene") { |_ctx|
        capture_view
      }

      @dialog.add_action_callback("upload_image") { |_ctx|
        upload_custom_image
      }

      @dialog.add_action_callback("download_result") { |_ctx|
        download_result
      }

      @dialog.add_action_callback("render_ai") { |_ctx, detail_value|
        render_scene(detail_value)
      }

      @dialog.show
    end

    def self.capture_view
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

      if view.write_image(options)
        @last_capture = path
        @capture_source = :capture
        escaped_path = path.gsub('\\', '/')
        safe_execute("setBeforeAfter('file:///#{escaped_path}', '')")
        safe_execute("setStatusText('Capture berhasil')")
      else
        safe_execute("setStatusText('❌ Gagal capture')")
      end
    end

    def self.upload_custom_image

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

      @last_capture = path
      @capture_source = :upload
      escaped_path = path.gsub('\\', '/')
      safe_execute("setBeforeAfter('file:///#{escaped_path}', '')")
      safe_execute("setStatusText('Gambar custom dipilih')")
    end

    def self.download_result
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

    def self.render_scene(detail_value)
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

    def self.start_google_oauth
      return if @oauth_in_progress

      @oauth_in_progress = true
      @oauth_state = SecureRandom.hex(16)
      @oauth_stop = false

      begin
        start_oauth_server
        auth_url = build_google_auth_url(@oauth_state)
        UI.openURL(auth_url)
        @dialog&.execute_script("setStatusText('Silakan login di browser...')")
      rescue => e
        @dialog&.execute_script("window.onGoogleOAuthError('Gagal memulai OAuth: #{escape_js(e.message)}')")
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
        @dialog&.execute_script("window.onGoogleOAuthError('Gagal start server: #{escape_js(e.message)}')")
        @oauth_in_progress = false
        raise
      end
    end

    def self.poll_oauth_server
      # Timeout after 60 seconds
      if Time.now - @oauth_start_time > 60
        puts "[Muko] OAuth timeout"
        @dialog&.execute_script("window.onGoogleOAuthError('⏱️ Login timeout. Silakan coba lagi.')")
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
          @dialog&.execute_script("window.onGoogleOAuthError('⚠️ State OAuth tidak valid. Silakan coba lagi.')")
          client.close
          stop_oauth_server
          return
        end

        if params['error'] && params['error'].first
          message = params['error_description']&.first || params['error']&.first
          html = build_callback_html('Login Dibatalkan', 'Anda membatalkan proses login. Silakan tutup tab ini dan coba lagi dari SketchUp.', 'cancel', false)
          write_http_response(client, 400, 'Bad Request', html)
          @dialog&.execute_script("window.onGoogleOAuthError('⚠️ Login dibatalkan. Silakan coba lagi.')")
          client.close
          stop_oauth_server
          return
        end

        code = params['code']&.first
        if code.nil? || code.empty?
          html = build_callback_html('Kode Tidak Ditemukan', 'Kode OAuth tidak ditemukan. Silakan coba login kembali.', 'error', false)
          write_http_response(client, 400, 'Bad Request', html)
          @dialog&.execute_script("window.onGoogleOAuthError('❌ Kode OAuth tidak ditemukan.')")
          client.close
          stop_oauth_server
          return
        end

        # Show processing state
        @dialog&.execute_script("setStatusText('Memproses login...')")

        token_data = exchange_code_for_token(code)
        if token_data['error']
          html = build_callback_html('Token Gagal', "Gagal mendapatkan token: #{token_data['error_description'] || token_data['error']}", 'error', false)
          write_http_response(client, 400, 'Bad Request', html)
          @dialog&.execute_script("window.onGoogleOAuthError('❌ Gagal mendapatkan token akses.')")
          client.close
          stop_oauth_server
          return
        end

        user_info = fetch_google_user(token_data['access_token'])
        if user_info['error']
          html = build_callback_html('User Info Gagal', 'Gagal mendapatkan informasi pengguna dari Google.', 'error', false)
          write_http_response(client, 400, 'Bad Request', html)
          @dialog&.execute_script("window.onGoogleOAuthError('❌ Gagal mendapatkan info pengguna.')")
          client.close
          stop_oauth_server
          return
        end

        name = user_info['name'] || user_info['email']
        email = user_info['email']
        photo = user_info['picture']

        html = build_callback_html('Login Berhasil!', "Selamat datang, #{name}! Tab ini akan ditutup otomatis dalam 2 detik.", 'success', true)
        write_http_response(client, 200, 'OK', html)
        @dialog&.execute_script("window.onGoogleOAuthSuccess('#{escape_js(name)}', '#{escape_js(email)}', '#{escape_js(photo)}')")
        
        client.close
        stop_oauth_server
        
      rescue IO::WaitReadable, Errno::EAGAIN
        # No connection yet, wait for next timer tick
      rescue => e
        puts "[Muko] OAuth server error: #{e.message}"
        puts e.backtrace.join("\n")
        @dialog&.execute_script("window.onGoogleOAuthError('OAuth error: #{escape_js(e.message)}')")
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

    def self.safe_execute(script)
      return unless @dialog
      UI.start_timer(0, false) do
        @dialog.execute_script(script)
      end
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
        safe_execute("setStatusText('⏱️ Render timeout')")
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

      toolbar.add_item(cmd_muko_ai)
      toolbar.show

      UI.menu("Extensions").add_item(EXTENSION_NAME) { open_dialog }

      file_loaded(__FILE__)
    end
  end
end