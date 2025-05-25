require 'aws-sdk-s3'
require 'sqlite3'
require 'ffi'
require 'opentimestamps'
require 'fileutils'
require 'date'
require 'json'

# Configuration
R2_ENDPOINT = 'https://<your-account-id>.r2.cloudflarestorage.com' # Replace with your R2 Account ID
R2_ACCESS_KEY_ID = ENV['R2_ACCESS_KEY_ID'] # Set in environment
R2_SECRET_ACCESS_KEY = ENV['R2_SECRET_ACCESS_KEY'] # Set in environment
R2_BUCKET_UNSIGNED = 'historical-media-unsigned'
R2_BUCKET_SIGNED = 'historical-media-signed'
DB_NAME = 'historical_media.db'
PRIVATE_KEY_FILE = 'ml_dsa_private_key.bin'
PUBLIC_KEY_FILE = 'ml_dsa_public_key.bin'
OTS_FILE_PATH = 'timestamps'

# Initialize Cloudflare R2 client (S3-compatible)
r2_client = Aws::S3::Client.new(
  access_key_id: R2_ACCESS_KEY_ID,
  secret_access_key: R2_SECRET_ACCESS_KEY,
  endpoint: R2_ENDPOINT,
  region: 'auto'
)

# FFI interface to liboqs for ML-DSA
module LibOQS
  extend FFI::Library
  ffi_lib 'oqs' # Assumes liboqs is installed
  attach_function :OQS_SIG_dilithium_2_new, [], :pointer
  attach_function :OQS_SIG_dilithium_2_keypair, [:pointer, :pointer, :pointer], :int
  attach_function :OQS_SIG_dilithium_2_sign, [:pointer, :pointer, :pointer, :size_t, :pointer, :size_t], :int
  attach_function :OQS_SIG_free, [:pointer], :void
end

# Generate or load ML-DSA key pair
def generate_key_pair
  unless File.exist?(PRIVATE_KEY_FILE)
    sig = LibOQS.OQS_SIG_dilithium_2_new
    public_key = FFI::MemoryPointer.new(:uint8, 1952) # ML-DSA-44 public key size
    private_key = FFI::MemoryPointer.new(:uint8, 4032) # ML-DSA-44 private key size
    LibOQS.OQS_SIG_dilithium_2_keypair(sig, public_key, private_key)
    File.binwrite(PUBLIC_KEY_FILE, public_key.read_string(1952))
    File.binwrite(PRIVATE_KEY_FILE, private_key.read_string(4032))
    LibOQS.OQS_SIG_free(sig)
  end
  [File.binread(PRIVATE_KEY_FILE), File.binread(PUBLIC_KEY_FILE)]
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
      signed_at TEXT,
      ots_proof BLOB
    )
  SQL
  db.close
end

# Script 1: Download video and upload to R2
def download_and_upload(url)
  video_id = nil
  video_title = nil
  FileUtils.mkdir_p('downloads')
  ytdlp_cmd = "yt-dlp --format 'bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best' " +
              "--output 'downloads/%(id)s.%(ext)s' --print-json '#{url}'"
  json_output = `#{ytdlp_cmd}`
  unless $?.success?
    raise "Failed to download video: #{url}"
  end

  video_info = JSON.parse(json_output)
  video_id = video_info['id']
  video_title = video_info['title']
  file_path = "downloads/#{video_id}.mp4"
  r2_key = "videos/#{video_id}.mp4"

  File.open(file_path, 'rb') do |file|
    r2_client.put_object(
      bucket: R2_BUCKET_UNSIGNED,
      key: r2_key,
      body: file
    )
  end

  db = SQLite3::Database.new(DB_NAME)
  db.execute(
    'INSERT INTO media (url, title, download_date, r2_path_unsigned) VALUES (?, ?, ?, ?)',
    [url, video_title, DateTime.now.iso8601, r2_key]
  )
  db.close

  [video_id, file_path, r2_key]
end

# Script 2: Sign, timestamp with OpenTimestamps, and upload to signed R2 bucket
def sign_and_upload
  private_key, _ = generate_key_pair
  db = SQLite3::Database.new(DB_NAME)
  videos = db.execute('SELECT id, r2_path_unsigned FROM media WHERE r2_path_signed IS NULL')

  FileUtils.mkdir_p('temp')
  FileUtils.mkdir_p(OTS_FILE_PATH)
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

    # Generate SHA-256 hash
    digest = OpenSSL::Digest::SHA256.new
    file_data = File.binread(local_path)
    hash = digest.digest(file_data)

    # Sign with ML-DSA
    sig = LibOQS.OQS_SIG_dilithium_2_new
    signature = FFI::MemoryPointer.new(:uint8, 2420) # ML-DSA-44 signature size
    signature_len = FFI::MemoryPointer.new(:size_t)
    message = FFI::MemoryPointer.from_string(file_data)
    LibOQS.OQS_SIG_dilithium_2_sign(sig, signature, signature_len, message, file_data.length, private_key)
    signature_data = signature.read_string(signature_len.read(:size_t))
    LibOQS.OQS_SIG_free(sig)

    # Create OpenTimestamps proof
    ots_file = "#{OTS_FILE_PATH}/#{id}.ots"
    timestamp = OpenTimestamps::Timestamp.new(hash)
    timestamp.attest(OpenTimestamps::Ops::OpAppend.new(id.to_s))
    File.binwrite(ots_file, timestamp.to_binary)
    # Run ots stamp to submit to Bitcoin blockchain
    system("ots stamp #{ots_file}")
    unless $?.success?
      puts "Warning: Failed to stamp timestamp for ID #{id}. Run 'ots stamp #{ots_file}' manually."
    end

    # Upload to signed bucket
    r2_key_signed = "signed/#{File.basename(r2_path_unsigned)}"
    File.open(local_path, 'rb') do |file|
      r2_client.put_object(
        bucket: R2_BUCKET_SIGNED,
        key: r2_key_signed,
        body: file
      )
    end

    # Upload OTS proof to R2
    r2_key_ots = "timestamps/#{id}.ots"
    File.open(ots_file, 'rb') do |file|
      r2_client.put_object(
        bucket: R2_BUCKET_SIGNED,
        key: r2_key_ots,
        body: file
      )
    end

    # Save metadata to database
    signed_at = DateTime.now.iso8601
    db.execute(
      'UPDATE media SET r2_path_signed = ?, signature = ?, signed_at = ?, ots_proof = ? WHERE id = ?',
      [r2_key_signed, signature_data, signed_at, File.binread(ots_file), id]
    )

    # Clean up
    File.delete(local_path)
    File.delete(ots_file)
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
  puts 'Signed, timestamped with OpenTimestamps, and uploaded all unsigned videos.'
end