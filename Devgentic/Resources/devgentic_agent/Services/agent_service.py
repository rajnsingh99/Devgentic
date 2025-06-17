# filename: Services/agent_service.py
import sys
from typing import List, Dict, Any, Optional, Union

from .base_service import BaseChatService
from ..Models.agent_models import AgentOrchestrationRequest, AgentConfig
from ..Models.common_models import GeneralChatResponse
from ..Models.ollama_models import LLMSettings as OllamaLLMSettings
from ..Models.remote_models import RemoteLLMSettings

# MODIFIED: Import the MCP tool manager instead of the static tool list
from ..Utils.mcp_tool_manager import mcp_tool_manager
from ..Utils.conversation_storage_manager import conversation_storage_manager

# Import LangChain components
from langchain import hub
from langchain.agents import AgentExecutor, create_openai_tools_agent
from langchain_core.messages import HumanMessage, AIMessage
from langchain_openai import ChatOpenAI
from langchain_google_genai import ChatGoogleGenerativeAI
from langchain_anthropic import ChatAnthropic
from langchain_ollama.chat_models import ChatOllama


class AgentService(BaseChatService):
    """
    Service for orchestrating a hierarchy of agents to perform complex tasks.
    MODIFIED: Now uses the McpToolManager to get a dynamic list of all available tools.
    """

    def _format_history_for_agent(self, history_entries: List[Dict[str, Any]]) -> List[Union[HumanMessage, AIMessage]]:
        """
        Converts raw history dictionaries into a list of LangChain message objects.
        """
        messages = []
        for entry in history_entries:
            role = entry.get("role", "user").lower()
            content = entry.get("text", "")
            if not content:
                continue

            if role == "user":
                messages.append(HumanMessage(content=content))
            elif role in ["ai", "assistant"]:
                messages.append(AIMessage(content=content))
        return messages

    def _create_agent_executor(
            self,
            agent_config: AgentConfig,
            all_available_tools: List[Any]
    ) -> AgentExecutor:
        """
        Factory function to create a single, configured AgentExecutor.
        It filters the master list of tools based on what the agent is allowed to use.
        """
        llm_settings = agent_config.llm_settings
        llm: Any = None
        if isinstance(llm_settings, RemoteLLMSettings):
            # ... (LLM instantiation logic is unchanged)
            if llm_settings.provider == "openai":
                llm = ChatOpenAI(model=llm_settings.model_name, openai_api_key=llm_settings.api_key, temperature=0)
            elif llm_settings.provider == "google":
                llm = ChatGoogleGenerativeAI(model=llm_settings.model_name, google_api_key=llm_settings.api_key,
                                             temperature=0)
            elif llm_settings.provider == "anthropic":
                llm = ChatAnthropic(model=llm_settings.model_name, anthropic_api_key=llm_settings.api_key,
                                    temperature=0)
        elif isinstance(llm_settings, OllamaLLMSettings):
            llm = ChatOllama(model=llm_settings.model_name, base_url=str(llm_settings.base_url), temperature=0)

        if not llm:
            raise ValueError(f"Could not instantiate LLM for agent '{agent_config.agent_id}'")

        # Filter the master tool list to get only the tools this agent can use
        agent_tools = [tool for tool in all_available_tools if tool.name in agent_config.tools]
        if not agent_tools:
            print(
                f"[AgentService] Warning: Agent '{agent_config.agent_id}' has no tools assigned or tools are invalid.",
                file=sys.stderr)

        try:
            prompt = hub.pull("hwchase17/openai-tools-agent")
        except Exception as e:
            raise RuntimeError(f"Could not pull prompt from LangChain Hub: {e}")

        agent = create_openai_tools_agent(llm, agent_tools, prompt)
        return AgentExecutor(agent=agent, tools=agent_tools, verbose=True)

    async def process_chat_interaction(self, request_payload: AgentOrchestrationRequest) -> GeneralChatResponse:
        """
        Orchestrates the execution of agents, now using a dynamic toolset from the manager.
        """
        conversation_id = request_payload.conversation_id
        root_agent_config = next((cfg for cfg in request_payload.agent_configs if cfg.parent_id is None), None)

        if not root_agent_config:
            raise ValueError("No root agent found in the orchestration request.")

        raw_history_messages = conversation_storage_manager.get_history(user_id=conversation_id, limit=20)
        chat_history_messages = self._format_history_for_agent(raw_history_messages)

        print(f"[AgentOrchestrator] Executing root agent: '{root_agent_config.agent_id}'")

        try:
            # MODIFIED: Get the complete, up-to-date list of all tools from the manager
            all_tools = mcp_tool_manager.get_all_tools()

            # Create the executor using the dynamic list of tools
            root_agent_executor = self._create_agent_executor(root_agent_config, all_tools)

            input_payload = {
                "input": root_agent_config.role_objective,
                "chat_history": chat_history_messages,
                "files": request_payload.files
            }

            result = await root_agent_executor.ainvoke(input_payload)
            final_answer = result.get("output", "The agent did not produce a final answer.")

        except Exception as e:
            print(f"Error executing agent '{root_agent_config.agent_id}': {e}", file=sys.stderr)
            raise RuntimeError(f"An error occurred during agent execution: {e}")

        top_level_objective = root_agent_config.role_objective
        conversation_storage_manager.add_message(data=top_level_objective, user_id=conversation_id, role="user")
        if final_answer:
            conversation_storage_manager.add_message(data=final_answer, user_id=conversation_id, role="ai")

        return GeneralChatResponse(
            response=final_answer,
            conversation_id=conversation_id
        )


# Create a singleton instance
agent_service = AgentService()
