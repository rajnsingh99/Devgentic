import argparse
import sys
import os
import subprocess
import tempfile
import shutil
import json # Import json for structured output

# --- Script Purpose ---
# This script is designed to automate the installation of Ollama and
# the pulling of specified Large Language Models (LLMs) on macOS.
# It is intended to be executed by a parent macOS application (written in Swift).
# The Swift application will handle user interaction, display progress,
# and manage necessary administrator privileges for certain steps.

# Define the URL for the latest macOS Ollama installer package
OLLAMA_INSTALLER_URL = "https://ollama.com/download/Ollama-latest.pkg"

# Define a marker to signal the need for elevated privileges
PRIVILEGE_ESCALATION_MARKER = "###REQUIRES_ELEVATED_PRIVILEGES###"

def is_ollama_installed():
    """
    Checks if Ollama is already installed on the system.

    Returns:
        bool: True if Ollama is detected, False otherwise.
    """
    print("--- Stage 2: Checking for existing Ollama installation ---")

    # Check for the Ollama application bundle in the standard Applications directory
    ollama_app_path = "/Applications/Ollama.app"
    if os.path.exists(ollama_app_path):
        print(f"Found Ollama application bundle at: {ollama_app_path}")
        print("--- Stage 2 Complete: Ollama found via application bundle ---")
        return True

    print(f"Ollama application bundle not found at: {ollama_app_path}")

    # Check if the 'ollama' command is available in the system's PATH
    try:
        # Use subprocess.run to execute 'ollama --version'
        # capture_output=True captures stdout and stderr
        # text=True decodes stdout/stderr as text
        # check=True raises CalledProcessError if the command returns a non-zero exit code
        # We use a timeout to prevent hanging if ollama is installed but unresponsive
        subprocess.run(['ollama', '--version'], capture_output=True, text=True, check=True, timeout=5) # Reduced timeout for quicker check
        print("Found 'ollama' command in system PATH.")
        print("--- Stage 2 Complete: Ollama found via command line ---")
        return True
    except FileNotFoundError:
        # 'ollama' command not found
        print("'ollama' command not found in system PATH.")
    except subprocess.CalledProcessError as e:
        # 'ollama' command found but returned an error (e.g., not running)
        # This might still indicate Ollama is installed but needs to be started.
        # For the purpose of this check, we'll consider it potentially installed.
        print(f"'ollama' command executed but returned an error: {e}")
        print(f"Stderr: {e.stderr}")
        print("Assuming Ollama is installed but may not be running.")
        print("--- Stage 2 Complete: Ollama command found (with error) ---")
        return True
    except subprocess.TimeoutExpired:
        print("'ollama' command check timed out. Assuming Ollama is installed but unresponsive.")
        print("--- Stage 2 Complete: Ollama command check timed out ---")
        return True
    except Exception as e:
        # Catch any other unexpected errors
        print(f"An unexpected error occurred while checking for 'ollama' command: {e}")


    print("--- Stage 2 Complete: Ollama not found ---")
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

        # In a real application, the Swift code would read from process.stdout
        # asynchronously to display progress and capture output.
        # For this script-only test, we'll just wait for it to finish and print a message.
        # We read line by line to simulate how a Swift app might process output
        print("Curl Output:")
        while True:
            line = process.stdout.readline()
            if not line:
                break
            # Decode and print the line (curl progress goes to stderr, now redirected to stdout)
            print(line.decode('utf-8').strip())


        process.wait() # Wait for the curl process to finish

        if process.returncode == 0:
            print("\nDownload complete.") # Add a newline after the progress bar
            print("--- Stage 3 Complete: Installer downloaded successfully ---")
            return installer_path
        else:
            print(f"\nError during download. Curl exited with code {process.returncode}")
            # Error details were printed line by line above
            print("--- Stage 3 Complete: Installer download failed ---")
            # Clean up the temporary directory if download failed
            if temp_dir and os.path.exists(temp_dir):
                 shutil.rmtree(temp_dir)
            return None

    except Exception as e:
        print(f"\nAn error occurred during the download process: {e}")
        print("--- Stage 3 Complete: Installer download failed ---")
        # Clean up the temporary directory in case of an exception
        if temp_dir and os.path.exists(temp_dir):
             shutil.rmtree(temp_dir)
        return None

def signal_and_run_installer(installer_path):
    """
    Signals to the calling application that the installer command needs
    elevated privileges and prints the command to be executed.

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

    print("--- Stage 4 Complete: Signal Sent ---")
    # The script execution pauses here from the perspective of the Python script's logic.
    # The Swift application is expected to detect the marker, execute the command
    # with privileges, and then potentially signal back or start a new script
    # for post-installation verification and LLM download.
    # For this script-only test, we'll just print a message about the next step.
    print("Note: In a real application, the Swift app would now execute the installer command with elevated privileges.")


def main():
    """
    Main function to parse arguments and initiate the setup process stages.
    """
    # --- Stage 1: Define Script Purpose and Accept Inputs ---
    parser = argparse.ArgumentParser(description="Automates Ollama and LLM setup on macOS.")
    parser.add_argument(
        'llm_names',
        metavar='LLM_NAME',
        type=str,
        nargs='+', # Expect one or more LLM names
        help='Names of the LLMs to download (e.g., llama3, mistral)'
    )

    # Parse the arguments provided to the script
    args = parser.parse_args()

    print("--- Ollama Setup Script Started ---")
    print(f"Received LLM names for download: {args.llm_names}")

    installer_path = None
    temp_dir_to_clean = None

    try:
        # --- Stage 2: Check for existing Ollama installation ---
        if is_ollama_installed():
            print("Ollama is already installed. Skipping installation steps.")
            # In a real script, we would proceed to LLM download here.
            # For now, we just print a message.
        else:
            print("Ollama is not installed. Proceeding with download and installation.")
            # --- Stage 3: Download Ollama macOS installer ---
            installer_path = download_ollama_installer()
            if installer_path:
                print(f"Ollama installer downloaded to: {installer_path}")
                temp_dir_to_clean = os.path.dirname(installer_path) # Remember temp dir for cleanup
                # --- Stage 4: Signal for Elevated Privileges to Run Installer ---
                signal_and_run_installer(installer_path)

                # After signaling, the Python script's direct responsibility for the installer
                # execution ends. The Swift app takes over.
                # The subsequent steps (Verifying Installation, LLM Download)
                # would likely be triggered by the Swift app after it confirms
                # the installer command's completion and success.
                # For the purpose of this staged script, we'll add placeholders
                # and notes for the next steps.

            else:
                print("Failed to download Ollama installer. Cannot proceed with installation.")
                sys.exit(1) # Exit with a non-zero code to indicate failure

        # --- Placeholder for future stages ---
        # 6. Verify Ollama installation (after Swift app runs installer).
        # 7. Download specified LLM(s) using 'ollama pull'.
        # 8. Report progress and status.
        # 9. Handle errors.
        # 10. Clean up temporary files.

        # Note: The script as written here would finish after signaling.
        # In a real workflow, the Swift app would likely call the script again
        # or signal back to continue after the installer runs.
        # For our staged development, we'll add the LLM download and final
        # cleanup steps to this script's execution flow in later stages,
        # assuming the installer step was successful (which the Swift app confirms).

    except Exception as e:
        print(f"An unhandled error occurred during the script execution: {e}", file=sys.stderr)
        sys.exit(1) # Exit with a non-zero code for unhandled errors
    finally:
        # --- Stage 10: Clean up temporary files ---
        # This cleanup will run regardless of success or failure (except for sys.exit calls before this point)
        if temp_dir_to_clean and os.path.exists(temp_dir_to_clean):
             print(f"Cleaning up temporary directory: {temp_dir_to_clean}")
             shutil.rmtree(temp_dir_to_clean)
             print("Temporary directory cleaned.")


    print("--- Script Finished ---")


if __name__ == "__main__":
    main()
