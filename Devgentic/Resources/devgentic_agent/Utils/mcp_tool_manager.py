# filename: Utils/mcp_tool_manager.py
import json
import httpx
import sys
import threading
from pathlib import Path
from typing import List, Dict, Any

from langchain.tools import DynamicTool

# Import our locally defined tools
from .agent_tools import available_tools as local_tools


class McpToolManager:
    """
    Manages the lifecycle of tools available to agents, dynamically loading
    tools from both local definitions and remote MCP servers specified in a
    configuration file. This manager is designed to be thread-safe.
    """

    def __init__(self, config_path: str = "mcp_servers.json"):
        self.config_path = Path(config_path)
        self._tools: List[Any] = []
        self._lock = threading.Lock()
        self.load_and_register_tools()

    def load_and_register_tools(self):
        """
        Reads the MCP server configuration file, fetches tools from all enabled
        remote servers, combines them with local tools, and registers them for use.
        This method is thread-safe and can be called to hot-reload the configuration.
        """
        print("[McpToolManager] Starting to load and register tools...")
        with self._lock:
            new_tools = []

            # 1. Add locally defined tools first
            new_tools.extend(local_tools)
            print(f"[McpToolManager] Registered {len(local_tools)} local tool(s).")

            # 2. Read the remote server configuration
            if not self.config_path.exists():
                print(
                    f"[McpToolManager] Warning: Configuration file not found at '{self.config_path}'. No remote tools will be loaded.",
                    file=sys.stderr)
                self._tools = new_tools
                return

            try:
                with open(self.config_path, 'r') as f:
                    servers_config = json.load(f)
            except (json.JSONDecodeError, IOError) as e:
                print(f"[McpToolManager] Error reading config file '{self.config_path}': {e}", file=sys.stderr)
                self._tools = new_tools
                return

            # 3. Fetch tools from each enabled remote server
            for server_config in servers_config:
                if server_config.get("enabled"):
                    name = server_config.get("name")
                    url = server_config.get("url")
                    print(f"[McpToolManager] Fetching tools from enabled server: '{name}' at {url}")
                    try:
                        # According to MCP spec, tools are listed at a standard endpoint
                        response = httpx.get(f"{url}/tools/list", timeout=5.0)
                        response.raise_for_status()
                        remote_tool_defs = response.json().get("tools", [])

                        for tool_def in remote_tool_defs:
                            # Create a LangChain DynamicTool from the MCP definition
                            dynamic_tool = self._create_dynamic_tool(url, tool_def)
                            new_tools.append(dynamic_tool)

                        print(
                            f"[McpToolManager] Successfully registered {len(remote_tool_defs)} tool(s) from '{name}'.")

                    except httpx.RequestError as e:
                        print(f"[McpToolManager] Error connecting to MCP server '{name}' at {url}: {e}",
                              file=sys.stderr)
                    except Exception as e:
                        print(f"[McpToolManager] Error processing tools from '{name}': {e}", file=sys.stderr)

            self._tools = new_tools
            print(f"[McpToolManager] Tool registration complete. Total tools available: {len(self._tools)}")

    def _create_dynamic_tool(self, server_url: str, tool_def: Dict[str, Any]) -> DynamicTool:
        """
        Creates a LangChain DynamicTool that knows how to call a remote MCP tool.
        """
        tool_name = tool_def.get("name")
        tool_desc = tool_def.get("description")

        async def _call_remote_tool(**kwargs):
            """The actual function that will be executed when the agent uses this tool."""
            try:
                async with httpx.AsyncClient(timeout=30.0) as client:
                    response = await client.post(
                        f"{server_url}/tools/call",
                        json={"name": tool_name, "arguments": kwargs}
                    )
                    response.raise_for_status()
                    return response.json()
            except Exception as e:
                return f"Failed to execute remote tool '{tool_name}'. Error: {e}"

        # The DynamicTool constructor creates a runnable tool from a function
        return DynamicTool(
            name=tool_name,
            func=None,  # Not needed when using coroutine
            coroutine=_call_remote_tool,
            description=tool_desc,
        )

    def get_all_tools(self) -> List[Any]:
        """
        Returns a thread-safe copy of the current list of all registered tools.
        """
        with self.lock:
            return self._tools.copy()


# Create a singleton instance to be used across the application
mcp_tool_manager = McpToolManager()
