# Historical Media Archiving Project

This project archives historical media (e.g., YouTube videos) with quantum-resistant cryptographic signatures and tamper-proof timestamps to ensure authenticity and protect against AI-generated distortions. Videos are downloaded, stored in Cloudflare R2, signed with ML-DSA (CRYSTALS-Dilithium), and timestamped using OpenTimestamps (OTS) on the Bitcoin blockchain. Metadata, including download and signing timestamps, is saved in a SQLite database.

## Prerequisites

- **Ruby**: Version 3.0 or later.
- **yt-dlp**: For downloading YouTube videos.
- **Cloudflare R2**: For storing unsigned and signed media files.
- **SQLite**: For metadata storage (included with Ruby).
- **liboqs**: For ML-DSA quantum-resistant signatures.
- **OpenTimestamps CLI**: For timestamping on the Bitcoin blockchain.

## Installation

1. **Install Ruby**:
   - On macOS/Linux: Use `rbenv` or `rvm`. Example:
     ```bash
     brew install rbenv
     rbenv install 3.2.2
     rbenv global 3.2.2
     ```
   - On Windows: Use RubyInstaller (https://rubyinstaller.org/).

2. **Install Ruby Dependencies**:
   - Install gems:
     ```bash
     gem install aws-sdk-s3 sqlite3 ffi opentimestamps
     ```

3. **Install yt-dlp**:
   - Install Python (3.8+).
   - Install `yt-dlp`:
     ```bash
     pip install yt-dlp
     ```
   - Verify:
     ```bash
     yt-dlp --version
     ```

4. **Install liboqs** (for ML-DSA):
   - On macOS/Linux: Follow the Open Quantum Safe guide (https://github.com/open-quantum-safe/liboqs).
     - Example for Ubuntu:
       ```bash
       sudo apt install cmake gcc ninja-build libssl-dev
       git clone https://github.com/open-quantum-safe/liboqs.git
       cd liboqs
       mkdir build && cd build
       cmake -GNinja ..
       ninja
       sudo ninja install
       ```
   - Ensure `liboqs.so` is in your system’s library path (e.g., `/usr/local/lib`).

5. **Install OpenTimestamps CLI**:
   - Install:
     ```bash
     pip install opentimestamps-client
     ```
   - Verify:
     ```bash
     ots --version
     ```

6. **Set Up Cloudflare R2**:
   - Create an R2 account (https://www.cloudflare.com/developer-platform/r2/).
   - Create buckets: `historical-media-unsigned` and `historical-media-signed`.
   - Obtain R2 credentials (Access Key ID, Secret Access Key, Account ID) from the Cloudflare dashboard.
   - Set environment variables:
     ```bash
     export R2_ACCESS_KEY_ID='your-access-key-id'
     export R2_SECRET_ACCESS_KEY='your-secret-access-key'
     ```
   - Update `R2_ENDPOINT` in `historical_media.rb`:
     ```ruby
     R2_ENDPOINT = 'https://<your-account-id>.r2.cloudflarestorage.com'
     ```

7. **Prepare Directories**:
   ```bash
   mkdir downloads temp timestamps
   ```

## Running the Scripts

The `historical_media.rb` script performs two tasks:
1. Downloads a YouTube video, uploads it to the `historical-media-unsigned` R2 bucket, and stores metadata in `historical_media.db`.
2. Signs unsigned videos with ML-DSA, timestamps the hash with OpenTimestamps, and uploads to the `historical-media-signed` R2 bucket, updating the database with the signature, `signed_at` timestamp, and OTS proof.

### Steps

1. **Clone the Repository**:
   ```bash
   git clone https://github.com/preserve-history/historical-media-archive.git
   cd historical-media-archive
   ```

2. **Run the Script**:
   - Execute:
     ```bash
     ruby historical_media.rb
     ```
   - Enter a YouTube URL (e.g., `https://www.youtube.com/watch?v=dQw4w9WgXcQ`).
   - The script will:
     - Download the video and upload to `historical-media-unsigned`.
     - Store metadata (URL, title, download date, R2 path) in `historical_media.db`.
     - Sign with ML-DSA, timestamp with OTS (via Bitcoin blockchain), and upload to `historical-media-signed`.
     - Store the signature, `signed_at`, and OTS proof in the database.
   - If OTS stamping fails, run manually:
     ```bash
     ots stamp timestamps/<id>.ots
     ```

3. **Verify Metadata**:
   - Check the SQLite database:
     ```bash
     sqlite3 historical_media.db "SELECT id, url, title, download_date, signed_at, r2_path_signed FROM media;"
     ```
   - Example output:
     ```
     1|https://www.youtube.com/watch?v=dQw4w9WgXcQ|Sample Video|2025-05-25T10:48:00Z|2025-05-25T10:49:00Z|signed/dQw4w9WgXcQ.mp4
     ```

4. **Verify Signatures and Timestamps**:
   - **Signature Verification** (ML-DSA):
     ```ruby
     require 'ffi'
     module LibOQS
       extend FFI::Library
       ffi_lib 'oqs'
       attach_function :OQS_SIG_dilithium_2_new, [], :pointer
       attach_function :OQS_SIG_dilithium_2_verify, [:pointer, :pointer, :size_t, :pointer, :size_t, :pointer], :int
       attach_function :OQS_SIG_free, [:pointer], :void
     end

     def verify_signature(file_path, signature, public_key_path)
       sig = LibOQS.OQS_SIG_dilithium_2_new
       message = FFI::MemoryPointer.from_string(File.binread(file_path))
       signature_ptr = FFI::MemoryPointer.from_string(signature)
       public_key = FFI::MemoryPointer.from_string(File.binread(public_key_path))
       result = LibOQS.OQS_SIG_dilithium_2_verify(sig, message, message.size, signature_ptr, signature.size, public_key)
       LibOQS.OQS_SIG_free(sig)
       result == 0 ? 'Valid' : 'Invalid'
     end
     ```
     - Download the signed file and signature from the database to verify.
   - **Timestamp Verification** (OTS):
     ```bash
     ots verify timestamps/<id>.ots
     ```
     - This checks the timestamp against the Bitcoin blockchain.

## Project Structure

- `historical_media.rb`: Main script for downloading, signing, timestamping, and uploading.
- `downloads/`: Temporary directory for downloaded videos.
- `temp/`: Temporary directory for signing.
- `timestamps/`: Directory for OTS proof files.
- `historical_media.db`: SQLite database for metadata.
- `ml_dsa_private_key.bin`: ML-DSA private key (generated automatically).
- `ml_dsa_public_key.bin`: ML-DSA public key for verification.

## Notes

- **Security**: Keep `ml_dsa_private_key.bin` secure and never share it. Share `ml_dsa_public_key.bin` for verification.
- **Quantum Resistance**: ML-DSA signatures and SHA-256 hashing are quantum-resistant, ensuring long-term security. OTS uses Bitcoin’s blockchain for tamper-proof timestamps.
- **Legal**: Ensure compliance with YouTube’s terms and copyright laws when downloading videos.
- **Troubleshooting**:
  - If `yt-dlp` fails, verify it’s in your PATH.
  - If OTS stamping fails, check internet connectivity or run `ots stamp` manually.
  - If `liboqs` errors occur, ensure it’s installed and accessible (e.g., `LD_LIBRARY_PATH`).

## Contributing

We need developers, archivists, and cryptographers to enhance this project. To contribute:
- Fork the repository and submit pull requests.
- Report issues or suggest features on GitHub Issues.
- Contact: `preservehistory@example.com`.

*Last updated: May 25, 2025*