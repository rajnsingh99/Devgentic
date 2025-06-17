# filename: Services/remote_service.py
import sys

from .base_service import BaseChatService
from ..Models.remote_models import RemoteChatRequest
from ..Models.common_models import GeneralChatResponse
from ..Utils.conversation_storage_manager import conversation_storage_manager, format_conversation_history_for_prompt
from ..Utils.vectorstore_client import vector_store_manager, format_chroma_context_for_prompt
from ..Utils.context_manager import context_manager
from ..Utils.prompt_factory import get_prompt_template
# Import the new file processing utility
from ..Utils.file_processor import read_files_from_uris

from langchain_core.output_parsers import StrOutputParser


class RemoteService(BaseChatService):
    """
    Service for handling chat interactions with remote LLM providers.
    MODIFIED: Now includes file processing capabilities.
    """

    def _get_llm_instance(self, llm_settings):
        # ... (same as before)
        provider = llm_settings.provider
        api_key = llm_settings.api_key
        model_name = llm_settings.model_name

        if provider == "openai":
            try:
                from langchain_openai import ChatOpenAI
                return ChatOpenAI(model=model_name, openai_api_key=api_key)
            except ImportError:
                raise RuntimeError("langchain-openai is not installed. Please run 'pip install langchain-openai'")

        elif provider == "google":
            try:
                from langchain_google_genai import ChatGoogleGenerativeAI
                return ChatGoogleGenerativeAI(model=model_name, google_api_key=api_key)
            except ImportError:
                raise RuntimeError(
                    "langchain-google-genai is not installed. Please run 'pip install langchain-google-genai'")

        elif provider == "anthropic":
            try:
                from langchain_anthropic import ChatAnthropic
                return ChatAnthropic(model=model_name, anthropic_api_key=api_key)
            except ImportError:
                raise RuntimeError("langchain-anthropic is not installed. Please run 'pip install langchain-anthropic'")

        else:
            raise NotImplementedError(f"Provider '{provider}' is not supported.")

    async def process_chat_interaction(self, request_payload: RemoteChatRequest) -> GeneralChatResponse:
        """
        Processes a chat request using provider-specific LLMs, prompt templates,
        and now includes attached file content.
        """
        conversation_id = request_payload.conversation_id
        user_prompt = request_payload.prompt
        llm_settings = request_payload.llm_settings
        files = [f.model_dump() for f in request_payload.files] if request_payload.files else []

        # 1. Instantiate the correct LLM.
        try:
            llm = self._get_llm_instance(llm_settings)
            print(f"[RemoteService] Instantiated model '{llm_settings.model_name}' for '{llm_settings.provider}'.")
        except Exception as e:
            raise RuntimeError(f"Failed to instantiate LLM: {e}")

        # 2. Retrieve all context sources: history, RAG, and now files.
        history_prompt_content = format_conversation_history_for_prompt(
            conversation_storage_manager.get_history(user_id=conversation_id, limit=50)
        )
        rag_context_content = format_chroma_context_for_prompt(
            vector_store_manager.retrieve_documents(query=user_prompt)
        )
        file_content = read_files_from_uris(files)

        # 3. Build the system prompt dynamically with all context.
        system_prompt_parts = ["You are a helpful and concise AI assistant."]
        if rag_context_content:
            system_prompt_parts.append(f"--- Context from Documents ---\n{rag_context_content}")
        if file_content:
            system_prompt_parts.append(file_content)  # file_content has its own header
        if history_prompt_content:
            system_prompt_parts.append(f"--- Chat History ---\n{history_prompt_content}")

        system_prompt = "\n\n".join(system_prompt_parts)

        # 4. Use the ContextManager.
        full_prompt_for_tokens = f"{system_prompt}\n\nUser: {user_prompt}"
        _, alert, suggestion = context_manager.manage_context(
            full_prompt_text=full_prompt_for_tokens,
            user_prompt=user_prompt,
            context_window_size=llm_settings.context_window_size
        )

        if alert:
            # Rebuild a simpler prompt if context is truncated
            file_content_if_alert = read_files_from_uris(files)  # Reread files as they are high priority
            system_prompt_parts_alert = [
                "You are a helpful and concise AI assistant. The prior conversation history was too long and has been omitted."]
            if file_content_if_alert:
                system_prompt_parts_alert.append(file_content_if_alert)
            system_prompt = "\n\n".join(system_prompt_parts_alert)

        # 5. Get the correct prompt template from the factory.
        prompt_template = get_prompt_template(llm_settings.provider)

        # 6. Build and invoke the chain.
        chain = prompt_template | llm | StrOutputParser()

        try:
            ai_response = await chain.ainvoke({
                "system_prompt": system_prompt,
                "user_prompt": user_prompt
            })
        except Exception as e:
            print(f"[RemoteService] Error invoking chain for '{llm_settings.provider}': {e}", file=sys.stderr)
            raise RuntimeError(f"API call failed: {e}")

        # 7. Persist and return.
        conversation_storage_manager.add_message(data=user_prompt, user_id=conversation_id, role="user")
        if ai_response:
            conversation_storage_manager.add_message(data=ai_response, user_id=conversation_id, role="ai")

        return GeneralChatResponse(
            response=ai_response or "Sorry, I could not generate a response.",
            conversation_id=conversation_id,
            alert=alert,
            suggestion=suggestion
        )


# Create a singleton instance
remote_service = RemoteService()
