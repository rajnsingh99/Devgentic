import argparse
import sys
import os
import subprocess
import tempfile
import shutil
import json
import time # Keep time for potential small delays in verification

# --- Script Purpose ---
# This script is designed to automate the installation of Ollama and
# the pulling of a specified Large Language Model (LLM) on macOS.
# It is intended to be executed by a parent macOS application (written in Swift).
# The Swift application will handle user interaction, display progress,
# and manage necessary administrator privileges for certain steps.
# The script now supports distinct 'initial' and 'post-install' phases,
# and expects zero or one LLM name as input.

# Define the URL for the latest macOS Ollama installer package
OLLAMA_INSTALLER_URL = "https://ollama.com/download/Ollama-latest.pkg"

# Define a marker to signal the need for elevated privileges
PRIVILEGE_ESCALATION_MARKER = "###REQUIRES_ELEVATED_PRIVILEGES###"

def is_ollama_installed():
    """
    Checks if Ollama is already installed on the system.
    This check is used both initially and after running the installer.

    Returns:
        bool: True if Ollama is detected, False otherwise.
    """
    # Check for the Ollama application bundle in the standard Applications directory
    ollama_app_path = "/Applications/Ollama.app"
    if os.path.exists(ollama_app_path):
        return True

    # Check if the 'ollama' command is available in the system's PATH
    # We need to ensure the environment for the subprocess includes standard paths
    # where ollama might be installed, like /usr/local/bin
    env = os.environ.copy()
    env['PATH'] = '/usr/local/bin:' + env.get('PATH', '') # Add /usr/local/bin to PATH

    try:
        # Use subprocess.run to execute 'ollama --version'
        # check=True raises CalledProcessError if the command returns a non-zero exit code
        # We use a timeout to prevent hanging if ollama is installed but unresponsive
        # Pass the modified environment
        subprocess.run(['ollama', '--version'], capture_output=True, text=True, check=True, timeout=5, env=env)
        return True
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        # If command not found, errors, or times out, assume not fully installed/running
        return False
    except Exception as e:
        # Catch any other unexpected errors during check
        print(f"An unexpected error occurred while checking for 'ollama' command: {e}", file=sys.stderr)
        return False


def download_ollama_installer():
    """
    Downloads the Ollama macOS installer package to a temporary directory.

    Returns:
        str or None: The path to the downloaded installer package if successful,
                     None otherwise.
    """
    print(f"--- Stage 3: Downloading Ollama installer from {OLLAMA_INSTALLER_URL} ---")

    # Create a temporary directory to store the downloaded installer
    temp_dir = None
    try:
        # Use mkdtemp to create a secure temporary directory
        temp_dir = tempfile.mkdtemp(prefix="ollama_installer_")
        installer_filename = OLLAMA_INSTALLER_URL.split('/')[-1] # Extract filename from URL
        installer_path = os.path.join(temp_dir, installer_filename)
        print(f"Downloading to temporary location: {installer_path}")

        # Use curl to download the file.
        # -L follows redirects
        # -o specifies the output file
        # -f fails silently on server errors
        # --progress-bar shows a progress bar (output might need parsing by Swift app)
        # We redirect stderr to stdout so Swift app can capture progress easily
        curl_command = ['curl', '-L', '-o', installer_path, '--progress-bar', OLLAMA_INSTALLER_URL]

        # Execute the curl command
        # We use Popen to allow the Swift app to read output incrementally.
        # stderr is redirected to stdout for easier capture by the Swift app.
        process = subprocess.Popen(curl_command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

        # Read output line by line to simulate Swift app processing and keep script responsive
        print("Curl Output:")
        while True:
            line = process.stdout.readline()
            if not line:
                break
            # Decode and print the line (curl progress goes to stderr, now redirected to stdout)
            # Use sys.stdout.flush() to ensure output is sent immediately
            sys.stdout.write(line.decode('utf-8'))
            sys.stdout.flush()


        process.wait() # Wait for the curl process to finish

        if process.returncode == 0:
            print("\nDownload complete.") # Add a newline after the progress bar
            print("--- Stage 3 Complete: Installer downloaded successfully ---")
            return installer_path
        else:
            print(f"\nError during download. Curl exited with code {process.returncode}", file=sys.stderr)
            # Error details were printed line by line above
            print("--- Stage 3 Complete: Installer download failed ---", file=sys.stderr)
            # Clean up the temporary directory if download failed
            if temp_dir and os.path.exists(temp_dir):
                 shutil.rmtree(temp_dir)
            return None

    except Exception as e:
        print(f"\nAn error occurred during the download process: {e}", file=sys.stderr)
        print("--- Stage 3 Complete: Installer download failed ---", file=sys.stderr)
        # Clean up the temporary directory in case of an exception
        if temp_dir and os.path.exists(temp_dir):
             shutil.rmtree(temp_dir)
        return None

def signal_installer_command(installer_path):
    """
    Signals to the calling application that the installer command needs
    elevated privileges and prints the command to be executed.
    This function does NOT run the installer itself.

    Args:
        installer_path (str): The path to the downloaded installer package.
    """
    print("--- Stage 4: Signaling for Elevated Privileges to Run Installer ---")

    # The command to run the installer silently
    installer_command = ['/usr/sbin/installer', '-pkg', installer_path, '-target', '/']

    print(f"Command to be executed with elevated privileges: {installer_command}")

    # Print the marker to signal the need for elevated privileges
    print(PRIVILEGE_ESCALATION_MARKER)

    # Print the command in a structured format (e.g., JSON) that the Swift app can parse
    # This ensures the Swift app gets the exact command and arguments
    command_payload = {"command": installer_command}
    print(json.dumps(command_payload))
    sys.stdout.flush() # Ensure marker and payload are sent immediately

    print("--- Stage 4 Complete: Signal Sent ---")
    print("Note: The Swift application should now execute the command above with elevated privileges.")
    # The Python script will exit after this phase.
    # The Swift app will call the script again for the 'post-install' phase.


def download_llm_model(llm_name):
    """
    Downloads the specified LLM model using the 'ollama pull' command.

    Args:
        llm_name (str): The name of the LLM to download.

    Returns:
        bool: True if the model was downloaded successfully, False otherwise.
    """
    print("--- Stage 7: Downloading LLM Model ---")
    if not llm_name:
        print("No LLM model specified for download. Skipping Stage 7.")
        return True # Consider successful if no model was requested

    print(f"Attempting to download model: {llm_name}")

    # Ensure /usr/local/bin is in the PATH for the ollama command
    env = os.environ.copy()
    env['PATH'] = '/usr/local/bin:' + env.get('PATH', '')

    # Use subprocess to run 'ollama pull <model_name>'
    # We use Popen to allow the Swift app to read output incrementally.
    # stderr is redirected to stdout as ollama pull sends progress to stderr.
    pull_command = ['ollama', 'pull', llm_name]
    try:
        # Pass the modified environment to the subprocess
        process = subprocess.Popen(pull_command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)

        # Read output line by line to simulate Swift app processing and keep script responsive
        print(f"Output for {llm_name}:")
        while True:
            line = process.stdout.readline()
            if not line:
                break
            # Decode and print the line (ollama pull progress goes to stderr, now redirected to stdout)
            sys.stdout.write(line.decode('utf-8'))
            sys.stdout.flush()

        process.wait() # Wait for the pull process to finish

        if process.returncode == 0:
            print(f"\nSuccessfully downloaded model: {llm_name}")
            print("--- Stage 7 Complete: LLM model downloaded successfully ---")
            return True
        else:
            print(f"\nError downloading model {llm_name}. Ollama pull exited with code {process.returncode}", file=sys.stderr)
            print("--- Stage 7 Complete: LLM model download failed ---", file=sys.stderr)
            return False

    except FileNotFoundError:
        print(f"Error: 'ollama' command not found during LLM download. Is Ollama installed and in PATH?", file=sys.stderr)
        print("--- Stage 7 Complete: LLM model download failed (ollama command not found) ---", file=sys.stderr)
        return False
    except Exception as e:
        print(f"An error occurred while pulling model {llm_name}: {e}", file=sys.stderr)
        print("--- Stage 7 Complete: LLM model download failed (exception) ---", file=sys.stderr)
        return False


def verify_and_download_llm(llm_name):
    """
    Performs post-installation verification (Stage 6) and downloads a single LLM (Stage 7).
    This function is called in the 'post-install' phase.

    Args:
        llm_name (str or None): The name of the LLM to download, or None if no LLM is selected.

    Returns:
        bool: True if verification and LLM download are successful, False otherwise.
    """
    print("--- Post-Install Phase: Starting Verification and LLM Download ---")

    # --- Stage 6: Verify Ollama installation after installer ---
    print("--- Stage 6: Verifying Ollama installation ---")
    # Add a small retry loop here in case Ollama service takes a moment to start
    max_retries = 10
    retry_delay = 2 # seconds
    ollama_verified = False
    for i in range(max_retries):
        if is_ollama_installed():
            ollama_verified = True
            break
        print(f"Ollama not detected yet, retrying in {retry_delay} seconds... (Attempt {i + 1}/{max_retries})")
        time.sleep(retry_delay)

    if ollama_verified:
        print("--- Stage 6 Complete: Ollama installation verified successfully. ---")
        # --- Stage 7: Download specified LLM(s) ---
        setup_successful = download_llm_model(llm_name)
        return setup_successful
    else:
        print("--- Stage 6 Complete: Ollama installation verification failed. ---", file=sys.stderr)
        print("Ollama does not appear to be installed or running after the installer was executed.", file=sys.stderr)
        return False # Verification failed


def main():
    """
    Main function to parse arguments and execute the appropriate phase.
    """
    parser = argparse.ArgumentParser(description="Automates Ollama and LLM setup on macOS.")
    parser.add_argument(
        '--phase',
        type=str,
        choices=['initial', 'post-install'],
        required=True,
        help="Execution phase: 'initial' (download and signal) or 'post-install' (verify and download LLM)"
    )
    parser.add_argument(
        'llm_name',
        metavar='LLM_NAME',
        type=str,
        nargs='?', # Allow 0 or 1 LLM name
        default=None, # Default to None if no LLM name is provided
        help='Name of the LLM to download (e.g., llama3). Optional.'
    )

    args = parser.parse_args()

    print(f"--- Ollama Setup Script Started (Phase: {args.phase}) ---")
    if args.llm_name:
        print(f"Received LLM name for download: {args.llm_name}")
    else:
        print("No LLM name specified for download.")


    temp_dir_to_clean = None
    setup_successful = False # Flag to track overall success

    try:
        if args.phase == 'initial':
            # Initial phase: Check if installed, download installer, signal for privileges
            print("--- Initial Phase: Checking installation, downloading, and signaling ---")
            if is_ollama_installed():
                print("--- Stage 2 Complete: Ollama is already installed. Skipping download and signaling. ---")
                setup_successful = True # Nothing to do in this phase, consider successful
            else:
                print("--- Stage 2 Complete: Ollama is not installed. Proceeding with download. ---")
                installer_path = download_ollama_installer()
                if installer_path:
                    temp_dir_to_clean = os.path.dirname(installer_path) # Remember temp dir for cleanup
                    signal_installer_command(installer_path)
                    setup_successful = True # Signaled successfully
                else:
                    print("Failed to download Ollama installer.", file=sys.stderr)
                    setup_successful = False # Download failed

        elif args.phase == 'post-install':
            # Post-install phase: Verify installation and download LLMs
            print("--- Post-Install Phase: Verifying installation and downloading LLM ---")
            # The Swift app is assumed to have run the installer before calling this phase.
            setup_successful = verify_and_download_llm(args.llm_name)

    except Exception as e:
        print(f"An unhandled error occurred during the script execution: {e}", file=sys.stderr)
        setup_successful = False # Unhandled error

    finally:
        # --- Stage 10: Clean up temporary files ---
        # This cleanup will run regardless of success or failure (except for sys.exit calls before this point)
        # Only clean up in the 'initial' phase if a temp dir was created
        if args.phase == 'initial' and temp_dir_to_clean and os.path.exists(temp_dir_to_clean):
             print(f"--- Stage 10: Cleaning up temporary directory: {temp_dir_to_clean} ---")
             shutil.rmtree(temp_dir_to_clean)
             print("--- Stage 10 Complete: Temporary directory cleaned. ---")
        # Note: Cleanup for the post-install phase (if needed, e.g., for failed LLM downloads)
        # would need separate consideration, but temporary files from the installer
        # download are only relevant to the initial phase.


    print("--- Ollama Setup Script Finished ---")
    if setup_successful:
        print("Overall setup phase completed successfully.")
        sys.exit(0) # Exit with success code
    else:
        print("Overall setup phase failed.", file=sys.stderr)
        sys.exit(1) # Exit with failure code


if __name__ == "__main__":
    main()

