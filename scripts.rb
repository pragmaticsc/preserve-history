require 'aws-sdk-s3'
require 'sqlite3'
require 'openssl'
require 'fileutils'
require 'date'

# Configuration
R2_ENDPOINT = 'https://<your-account-id>.r2.cloudflarestorage.com' # Replace with your R2 Account ID
R2_ACCESS_KEY_ID = ENV['R2_ACCESS_KEY_ID'] # Set in environment
R2_SECRET_ACCESS_KEY = ENV['R2_SECRET_ACCESS_KEY'] # Set in environment
R2_BUCKET_UNSIGNED = 'historical-media-unsigned'
R2_BUCKET_SIGNED = 'historical-media-signed'
DB_NAME = 'historical_media.db'
PRIVATE_KEY_FILE = 'private_key.pem'
PUBLIC_KEY_FILE = 'public_key.pem'

# Initialize Cloudflare R2 client (S3-compatible)
r2_client = Aws::S3::Client.new(
  access_key_id: R2_ACCESS_KEY_ID,
  secret_access_key: R2_SECRET_ACCESS_KEY,
  endpoint: R2_ENDPOINT,
  region: 'auto' # R2 uses 'auto' for region
)

# Generate or load RSA key pair
def generate_key_pair
  unless File.exist?(PRIVATE_KEY_FILE)
    key = OpenSSL::PKey::RSA.new(2048)
    # Save private key
    File.write(PRIVATE_KEY_FILE, key.to_pem)
    # Save public key
    File.write(PUBLIC_KEY_FILE, key.public_key.to_pem)
  end
  private_key = OpenSSL::PKey::RSA.new(File.read(PRIVATE_KEY_FILE))
  public_key = OpenSSL::PKey::RSA.new(File.read(PUBLIC_KEY_FILE))
  [private_key, public_key]
end

# Initialize SQLite database
def init_db
  db = SQLite3::Database.new(DB_NAME)
  db.execute <<-SQL
    CREATE TABLE IF NOT EXISTS media (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      url TEXT NOT NULL,
      title TEXT,
      download_date TEXT,
      r2_path_unsigned TEXT,
      r2_path_signed TEXT,
      signature BLOB,
      signed_at TEXT
    )
  SQL
  db.close
end

# Script 1: Download video and upload to R2
def download_and_upload(url)
  # Download video using yt-dlp
  video_id = nil
  video_title = nil
  FileUtils.mkdir_p('downloads')
  ytdlp_cmd = "yt-dlp --format 'bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best' " +
              "--output 'downloads/%(id)s.%(ext)s' --print-json '#{url}'"
  json_output = `#{ytdlp_cmd}`
  unless $?.success?
    raise "Failed to download video: #{url}"
  end

  # Parse yt-dlp JSON output
  video_info = JSON.parse(json_output)
  video_id = video_info['id']
  video_title = video_info['title']
  file_path = "downloads/#{video_id}.mp4"
  r2_key = "videos/#{video_id}.mp4"

  # Upload to R2
  File.open(file_path, 'rb') do |file|
    r2_client.put_object(
      bucket: R2_BUCKET_UNSIGNED,
      key: r2_key,
      body: file
    )
  end

  # Save metadata to SQLite
  db = SQLite3::Database.new(DB_NAME)
  db.execute(
    'INSERT INTO media (url, title, download_date, r2_path_unsigned) VALUES (?, ?, ?, ?)',
    [url, video_title, DateTime.now.iso8601, r2_key]
  )
  db.close

  [video_id, file_path, r2_key]
end

# Script 2: Sign videos and upload to signed R2 bucket
def sign_and_upload
  private_key, _ = generate_key_pair
  db = SQLite3::Database.new(DB_NAME)
  videos = db.execute('SELECT id, r2_path_unsigned FROM media WHERE r2_path_signed IS NULL')

  FileUtils.mkdir_p('temp')
  videos.each do |id, r2_path_unsigned|
    # Download from unsigned bucket
    local_path = "temp/#{File.basename(r2_path_unsigned)}"
    File.open(local_path, 'wb') do |file|
      r2_client.get_object(
        bucket: R2_BUCKET_UNSIGNED,
        key: r2_path_unsigned,
        response_target: file
      )
    end

    # Generate signature
    digest = OpenSSL::Digest::SHA256.new
    file_data = File.read(local_path)
    signature = private_key.sign(digest, file_data)
    signed_at = DateTime.now.iso8601

    # Upload to signed bucket
    r2_key_signed = "signed/#{File.basename(r2_path_unsigned)}"
    File.open(local_path, 'rb') do |file|
      r2_client.put_object(
        bucket: R2_BUCKET_SIGNED,
        key: r2_key_signed,
        body: file
      )
    end

    # Save signature, signed path, and signed_at to database
    db.execute(
      'UPDATE media SET r2_path_signed = ?, signature = ?, signed_at = ? WHERE id = ?',
      [r2_key_signed, signature, signed_at, id]
    )

    # Clean up
    File.delete(local_path)
  end
  db.close
end

# Main execution
if __FILE__ == $PROGRAM_NAME
  init_db
  puts 'Enter YouTube URL:'
  url = gets.chomp
  video_id, local_path, r2_key = download_and_upload(url)
  puts "Downloaded and uploaded video #{video_id} to R2: #{r2_key}"

  sign_and_upload
  puts 'Signed and uploaded all unsigned videos.'
end