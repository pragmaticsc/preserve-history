# Historical Media Archiving Project

This project archives historical media (YouTube videos) and cryptographically signs them to ensure authenticity and provenance, protecting against AI-generated distortions. Media is downloaded, stored in Cloudflare R2, and signed with RSA, with metadata (including download and signing timestamps) saved in a SQLite database.

## Prerequisites

- **Ruby**: Version 3.0 or later.
- **yt-dlp**: For downloading YouTube videos.
- **Cloudflare R2**: For storing unsigned and signed media files.
- **SQLite**: For metadata storage (included with Ruby).

## Installation

1. **Install Ruby**:
   - On macOS/Linux: Use a version manager like `rbenv` or `rvm`. Example:
     ```bash
     brew install rbenv
     rbenv install 3.4.4
     rbenv global 3.4.4
     ```
   - On Windows: Use RubyInstaller (https://rubyinstaller.org/).

2. **Install Ruby Dependencies**:
   - Install required gems:
     ```bash
     gem install aws-sdk-s3 sqlite3
     ```

3. **Install yt-dlp**:
   - Install Python (3.8+) if not already installed.
   - Install `yt-dlp`:
     ```bash
     pip install yt-dlp
     ```
   - Verify installation:
     ```bash
     yt-dlp --version
     ```

4. **Set Up Cloudflare R2**:
   - Create an R2 account at https://www.cloudflare.com/developer-platform/r2/.
   - Create two buckets: `historical-media-unsigned` and `historical-media-signed`.
   - Obtain your R2 credentials (Access Key ID, Secret Access Key, Account ID) from the Cloudflare dashboard.
   - Set environment variables:
     ```bash
     export R2_ACCESS_KEY_ID='your-access-key-id'
     export R2_SECRET_ACCESS_KEY='your-secret-access-key'
     ```
   - Update the `R2_ENDPOINT` in `historical_media.rb` with your Account ID:
     ```ruby
     R2_ENDPOINT = 'https://<your-account-id>.r2.cloudflarestorage.com'
     ```

5. **Prepare Directories**:
   - Create `downloads/` and `temp/` directories in the project root:
     ```bash
     mkdir downloads temp
     ```

## Running the Scripts

The `historical_media.rb` script handles two tasks:
1. Downloads a YouTube video, uploads it to the `historical-media-unsigned` R2 bucket, and stores metadata in `historical_media.db`.
2. Signs unsigned videos with an RSA private key, uploads them to the `historical-media-signed` R2 bucket, and updates the database with the signature and signing timestamp.

### Steps

1. **Clone the Repository**:
   ```bash
   git clone https://github.com/preserve-history/historical-media-archive.git
   cd historical-media-archive
   ```

2. **Run the Script**:
   - Execute the script:
     ```bash
     ruby historical_media.rb
     ```
   - Enter a YouTube URL when prompted (e.g., `https://www.youtube.com/watch?v=dQw4w9WgXcQ`).
   - The script will:
     - Download the video and upload it to `historical-media-unsigned`.
     - Store metadata (URL, title, download date, R2 path) in `historical_media.db`.
     - Sign the video, upload it to `historical-media-signed`, and update the database with the signed path, signature, and `signed_at` timestamp.

3. **Verify Metadata**:
   - Check the SQLite database:
     ```bash
     sqlite3 historical_media.db "SELECT id, url, title, download_date, signed_at, r2_path_signed FROM media;"
     ```
   - Example output:
     ```
     1|https://www.youtube.com/watch?v=dQw4w9WgXcQ|Sample Video|2025-05-25T10:19:00Z|2025-05-25T10:24:00Z|signed/dQw4w9WgXcQ.mp4
     ```

4. **Verify Signatures** (Optional):
   - Use the public key (`public_key.pem`) to verify a signed file:
     ```ruby
     require 'openssl'

     def verify_signature(file_path, signature, public_key_path)
       public_key = OpenSSL::PKey::RSA.new(File.read(public_key_path))
       digest = OpenSSL::Digest::SHA256.new
       file_data = File.read(file_path)
       public_key.verify(digest, signature, file_data) ? 'Valid' : 'Invalid'
     end
     ```
   - Download a signed file from the `historical-media-signed` bucket and retrieve its signature from the database to verify.

## Project Structure

- `historical_media.rb`: Main script for downloading, uploading, and signing media.
- `downloads/`: Temporary directory for downloaded videos.
- `temp/`: Temporary directory for signing process.
- `historical_media.db`: SQLite database for metadata.
- `private_key.pem`: RSA private key for signing (generated automatically).
- `public_key.pem`: RSA public key for verification (generated automatically).

## Notes

- **Security**: Keep `private_key.pem` secure and never share it. Back up `public_key.pem` for public verification.
- **Legal**: Ensure compliance with YouTube’s terms of service and copyright laws when downloading videos.
- **Troubleshooting**:
  - If `yt-dlp` fails, ensure it’s installed and accessible in your PATH.
  - Verify R2 credentials and bucket names if uploads fail.
  - Check `R2_ENDPOINT` in the script matches your Account ID.

## Contributing

We welcome contributions from developers, archivists, and cryptographers. To contribute:
- Fork the repository and submit pull requests.
- Report issues or suggest features on the GitHub Issues page.
- Contact us at `preservehistory@example.com`.

*Last updated: May 25, 2025*