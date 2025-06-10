# devgentic_agent/services/agent_service.py
import sys
from typing import Optional, Dict, Any, Tuple, List

from ..models.api_models import ChatRequest, AddDocumentRequest, ChatResponse, AddDocumentResponse, AgentConfigItem
from ..tools.conversation_storage_manager import conversation_storage_manager, format_conversation_history_for_prompt
from ..tools.vectorstore_client import vector_store_manager
from ..tools.langchain_components import langchain_pipeline_manager
from langchain_ollama.chat_models import ChatOllama
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import StrOutputParser

class AgentService:
    """Service layer containing the core business logic for the agent."""
    def __init__(self):
        self.is_ready = False
        self._last_agent_config_store: Dict[str, AgentConfigItem] = {}
        
        lc_status, lc_msg = langchain_pipeline_manager.get_status()
        self.is_ready = lc_status in ["ok", "degraded"]

        if not self.is_ready:
            print(f"AgentService initialized, but LangchainPipelineManager reported an error: {lc_msg}. Check logs.", file=sys.stderr)
        elif lc_status == "degraded":
            print(f"AgentService initialized, but LangchainPipelineManager reported a degraded state: {lc_msg}. Some operations might be affected.", file=sys.stdout)
        else:
            print("AgentService initialized and ready.", file=sys.stdout)

    def _format_files_for_prompt(self, files: List[Dict]) -> str:
        """Formats the list of file objects into a string for the LLM prompt."""
        if not files:
            return ""
        
        formatted_list = ["--- Attached Files ---"]
        for f in files:
            file_info = f"Name: {f.get('name', 'N/A')}, Type: {f.get('mime_type', 'N/A')}, Path: {f.get('uri')}"
            formatted_list.append(file_info)
        formatted_list.append("--- End of Files ---")
        
        return "\n".join(formatted_list) + "\n\n"

    def _has_agent_config_changed(self, conversation_id: str, new_config: AgentConfigItem) -> bool:
        """
        Compares the new agent config with the last known config for the conversation.
        Returns True if the config is new, has changed, or was not tracked previously.
        """
        last_config = self._last_agent_config_store.get(conversation_id)
        if not last_config:
            # If no config is stored, this is the first interaction or a new session.
            return True
        # Pydantic models can be compared directly for equality.
        return last_config != new_config

    async def _get_llm_conversation_summary(self, conversation_id: str, llm_instance: Optional[ChatOllama], history_limit: int = 20) -> str:
        if not llm_instance:
            return ""
        storage_status, _ = conversation_storage_manager.is_available()
        if storage_status in ["error", "disabled"]:
            return ""
        try:
            history_memories: List[Any] = conversation_storage_manager.get_history(user_id=conversation_id, limit=history_limit)
            if not history_memories:
                return ""
            history_memories.reverse()
            formatted_history = format_conversation_history_for_prompt(history_memories)
            summarization_prompt_text = (
                "You are an expert summarizer. Provide a concise summary of the following conversation, focusing on key topics, decisions, and unresolved questions.\n\n"
                f"Conversation History:\n{formatted_history}\n\nConcise Summary:"
            )
            prompt_template = ChatPromptTemplate.from_messages([("human", summarization_prompt_text)])
            summarization_chain = prompt_template | llm_instance | StrOutputParser()
            summary = await summarization_chain.ainvoke({})
            return summary.strip()
        except Exception as e:
            print(f"Error during LLM conversation summarization for {conversation_id}: {e}", file=sys.stderr)
            return ""

    async def _handle_model_change_and_get_summary(self, new_ollama_url: str, new_model_name: str, conversation_id: str, current_prompt: str) -> Tuple[str, Optional[str]]:
        """Handles LLM re-initialization, generates summary, and returns effective prompt."""
        requested_update_succeeded, operational_status_ok = langchain_pipeline_manager.update_llm_and_rebuild_chain(
            new_ollama_url=str(new_ollama_url),
            new_model_name=str(new_model_name)
        )
        client_error_message: Optional[str] = None
        if not operational_status_ok:
            error_detail = langchain_pipeline_manager.initialization_error or f"Critical failure during LLM update to {new_model_name}, and revert also failed."
            raise RuntimeError(error_detail)
        if not requested_update_succeeded and operational_status_ok:
            client_error_message = (
                f"Failed to switch to model '{new_model_name}'. "
                f"Continuing with the previous model ({langchain_pipeline_manager.current_model_name or 'default'}). "
                f"Details: {langchain_pipeline_manager.initialization_error or 'Unknown reason.'}"
            )
        current_llm_for_summary = langchain_pipeline_manager.llm
        llm_summary = await self._get_llm_conversation_summary(conversation_id, current_llm_for_summary)
        summary_prompt_prefix = ""
        if llm_summary:
            summary_prompt_prefix = (
                f"--- Start of Conversation Context (Summarized by AI) ---\n"
                f"{llm_summary}\n"
                f"--- End of Conversation Context ---\n\n"
            )
        return f"{summary_prompt_prefix}{current_prompt}", client_error_message

    async def process_chat_interaction(self, request_payload: ChatRequest) -> ChatResponse:
        conversation_id = request_payload.conversation_id
        user_prompt = request_payload.message_content.prompt
        files = [f.model_dump() for f in request_payload.message_content.files]
        active_agent_config = request_payload.agent_config[0]
        
        # Log the current agent and model for the incoming request
        print(f"--- New Request Received ---", flush=True)
        print(f"Agent: '{active_agent_config.role or active_agent_config.id}' | Model: '{active_agent_config.llm_settings.model_name}'", flush=True)

        # Prepend file information to the main prompt
        file_info_prompt = self._format_files_for_prompt(files)
        effective_prompt = f"{file_info_prompt}{user_prompt}"
        
        client_notification_message: Optional[str] = None

        if self._has_agent_config_changed(conversation_id, active_agent_config):
            last_config_model = self._last_agent_config_store.get(conversation_id)
            print(f"Detected model change for conversation {conversation_id}. Previous: {last_config_model.llm_settings.model_name if last_config_model else 'None'}. New: {active_agent_config.llm_settings.model_name}", flush=True)
            try:
                effective_prompt, client_notification_message = await self._handle_model_change_and_get_summary(
                    new_ollama_url=str(active_agent_config.llm_settings.base_url),
                    new_model_name=active_agent_config.llm_settings.model_name,
                    conversation_id=conversation_id,
                    current_prompt=effective_prompt # Pass prompt with file info
                )
            except RuntimeError as e:
                raise e # Propagate critical errors

        # Update the store with the new config for the next request
        self._last_agent_config_store[conversation_id] = active_agent_config

        # Add user message to conversation history
        storage_status, _ = conversation_storage_manager.is_available()
        if storage_status in ["ok", "degraded"]:
            conversation_storage_manager.add_message(data=user_prompt, user_id=conversation_id, role="user")
        
        # Invoke the Langchain pipeline
        ai_response_content = await langchain_pipeline_manager.invoke_chain(
            user_prompt=effective_prompt,
            conversation_id=conversation_id
        )

        # Add AI response to history
        if ai_response_content and storage_status in ["ok", "degraded"]:
            conversation_storage_manager.add_message(data=ai_response_content, user_id=conversation_id, role="ai")

        response_data = {"response": ai_response_content, "conversation_id": conversation_id}
        if client_notification_message:
            response_data["notification"] = client_notification_message
        print(f"--- Request Finished ---", flush=True)
        return ChatResponse(**response_data)

    def add_document_to_vectorstore(self, request_payload: AddDocumentRequest) -> AddDocumentResponse:
        if not vector_store_manager.vectorstore:
            raise RuntimeError("Vector store (ChromaDB) is not available.")
        doc_metadata = {"source": request_payload.source}
        if request_payload.metadata:
            doc_metadata.update(request_payload.metadata)
        success, doc_ids = vector_store_manager.add_documents(texts=[request_payload.text], metadatas=[doc_metadata])
        if success:
            doc_id = doc_ids[0] if doc_ids else None
            return AddDocumentResponse(
                message="Document added successfully to ChromaDB.",
                document_id=doc_id,
                text_preview=request_payload.text[:100] + "...",
                metadata=doc_metadata
            )
        else:
            raise RuntimeError("Failed to add document to ChromaDB.")

agent_service = AgentService()
