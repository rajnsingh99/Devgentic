# filename: Models/agent_models.py
from pydantic import BaseModel, Field, model_validator
from typing import Optional, List, Union

# Import the specific LLM settings from other models to be reused
from .ollama_models import LLMSettings as OllamaLLMSettings
from .remote_models import RemoteLLMSettings
from .remote_models import FileObject


class AgentConfig(BaseModel):
    """
    Defines the configuration for a single agent within the orchestration hierarchy.
    """
    # FIXED: Added model_config to allow population by alias and added aliases to fields
    model_config = {"populate_by_name": True}

    agent_id: str = Field(..., alias="agentId", description="A unique identifier for this agent within the request.")
    parent_id: Optional[str] = Field(None, alias="parentId",
                                     description="The agent_id of the parent agent. 'null' designates the root agent.")
    role_objective: str = Field(..., alias="roleObjective",
                                description="A clear, high-level objective for this specific agent.")
    tools: List[str] = Field(default_factory=list, description="A list of tool names this agent is allowed to use.")

    llm_settings: Union[OllamaLLMSettings, RemoteLLMSettings] = Field(..., alias="llmSettings",
                                                                      discriminator='provider')


class AgentOrchestrationRequest(BaseModel):
    """
    The main request model for the /agent/orchestrate endpoint. It defines the
    entire multi-agent hierarchy and the overall task.
    """
    model_config = {"populate_by_name": True}

    conversation_id: str = Field(..., alias="conversationId")
    files: Optional[List[FileObject]] = Field(default_factory=list,
                                              description="A list of files available to the entire orchestration.")
    agent_configs: List[AgentConfig] = Field(..., alias="agentConfigs", min_length=1)

    @model_validator(mode='after')
    def check_for_single_root_agent(self) -> 'AgentOrchestrationRequest':
        """
        Validates that there is exactly one root agent (parent_id is null)
        in the list of agent configurations.
        """
        root_agents = [agent for agent in self.agent_configs if agent.parent_id is None]
        if len(root_agents) != 1:
            raise ValueError(
                f"The agent configuration must have exactly one root agent (parent_id: null), but {len(root_agents)} were found.")
        return self
