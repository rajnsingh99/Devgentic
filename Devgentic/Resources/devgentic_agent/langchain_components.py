import sys
from typing import Optional, Dict, Any, List, Tuple
from langchain_ollama.chat_models import ChatOllama
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import StrOutputParser
from langchain_core.runnables import RunnablePassthrough, RunnableLambda, RunnableSerializable

from .config import OLLAMA_MODEL, OLLAMA_BASE_URL # Default initial model
# Import helper functions and managers from sibling tool modules
# Updated import to use the new centralized conversation storage manager
from .Utils.conversation_storage_manager import conversation_storage_manager, format_conversation_history_for_prompt
from .Utils.vectorstore_client import vector_store_manager, format_chroma_context_for_prompt

class LangchainPipelineManager:
    """
    Manages the Langchain LLM, prompt, and the main processing chain.
    Includes logic for updating the LLM and attempting to revert on failure.
    """
    def __init__(self):
        self.llm: Optional[ChatOllama] = None
        self._previous_llm: Optional[ChatOllama] = None # Store the last known good LLM
        self.current_model_name: Optional[str] = None
        self.current_ollama_url: Optional[str] = None

        self.prompt_template: Optional[ChatPromptTemplate] = None
        self.chain: Optional[RunnableSerializable[Dict, str]] = None
        self.initialization_error: Optional[str] = None

        self._chain_with_memory_and_rag: Optional[RunnableSerializable[Dict, Dict]] = None
        self._output_parser: Optional[StrOutputParser] = None

        self._initialize_components()

    def _get_chat_history(self, inputs: Dict[str, Any]) -> str:
        """Retrieves chat history from the active conversation storage backend."""
        conversation_id = inputs.get("conversation_id")
        storage_status, _ = conversation_storage_manager.is_available()

        if storage_status in ["error", "disabled"] or not conversation_id:
            print(f"Conversation history retrieval not available ({storage_status}) or no conversation_id.", file=sys.stderr)
            return "Chat history not available."

        # Get history from the active conversation storage backend
        raw_history_messages: List[Any] = conversation_storage_manager.get_history(user_id=conversation_id, limit=10)
        if raw_history_messages:
            # The format_conversation_history_for_prompt expects items in chronological order
            # and will reverse them for the prompt if needed.
            return format_conversation_history_for_prompt(raw_history_messages)
        return "No chat history found for this conversation."


    def _get_context_from_chroma(self, inputs: Dict[str, Any]) -> str:
        user_prompt = inputs.get("user_prompt")
        if not vector_store_manager.retriever or not user_prompt:
            return "Context retrieval not available (ChromaDB not configured or no user_prompt)."
        docs = vector_store_manager.retrieve_documents(query=user_prompt)
        return format_chroma_context_for_prompt(docs)

    def _build_chain_prefix(self) -> Optional[RunnableSerializable[Dict, Dict]]:
        try:
            return RunnablePassthrough.assign(
                chat_history=RunnableLambda(self._get_chat_history), # Use the unified history getter
                context=RunnableLambda(self._get_context_from_chroma)
            )
        except Exception as e:
            self.initialization_error = (self.initialization_error + "\n" if self.initialization_error else "") + f"Error building chain prefix: {e}"
            print(f"Error building chain prefix: {e}", file=sys.stderr)
            return None

    def _rebuild_chain_with_current_llm(self) -> bool:
        """Attempts to rebuild the chain with the current self.llm and other components."""
        if self.llm and self.prompt_template and self._chain_with_memory_and_rag and self._output_parser:
            try:
                self.chain = self._chain_with_memory_and_rag | self.prompt_template | self.llm | self._output_parser
                print(f"Chain successfully rebuilt with LLM: {self.current_model_name or 'current model'}", file=sys.stdout)
                # Clear error if rebuild is successful with a valid LLM
                if self.llm: # Check if llm is not None
                     self.initialization_error = None
                return True
            except Exception as e:
                error_msg = f"Error rebuilding chain with LLM {self.current_model_name or 'current model'}: {e}"
                self.initialization_error = (self.initialization_error + "\n" if self.initialization_error else "") + error_msg
                print(error_msg, file=sys.stderr)
                self.chain = None # Ensure chain is None if rebuild fails
                return False
        else:
            error_msg = "Cannot rebuild chain: one or more essential components (LLM, prompt, chain_prefix, parser) are missing."
            self.initialization_error = (self.initialization_error + "\n" if self.initialization_error else "") + error_msg
            print(error_msg, file=sys.stderr)
            self.chain = None
            return False

    def _initialize_components(self):
        current_errors: List[str] = []

        try:
            # Use defaults from config.py for initial setup
            self.current_ollama_url = OLLAMA_BASE_URL
            self.current_model_name = OLLAMA_MODEL
            initial_llm = ChatOllama(model=self.current_model_name, base_url=self.current_ollama_url)
            self.llm = initial_llm
            self._previous_llm = initial_llm # Set previous LLM on successful initial load
            print(f"ChatOllama LLM initialized with model: {self.current_model_name}, base_url: {self.current_ollama_url}")
        except Exception as e:
            error_msg = f"Error initializing Langchain LLM with {self.current_model_name}: {e}"
            current_errors.append(error_msg)
            print(error_msg, file=sys.stderr)
            self.llm = None # Ensure LLM is None if init fails
            self._previous_llm = None
            self.current_model_name = None
            self.current_ollama_url = None


        try:
            self.prompt_template = ChatPromptTemplate.from_messages([
                ("system", (
                    "You are a helpful AI assistant. Answer the user's questions to the best of your ability. "
                    "Use the provided chat history and retrieved context to inform your responses. "
                    "If the context or history is not relevant, rely on your general knowledge.\n\n"
                    "Chat History:\n{chat_history}\n\n"
                    "Retrieved Context from Documents:\n{context}"
                )),
                ("user", "{user_prompt}")
            ])
        except Exception as e:
            error_msg = f"Error creating ChatPromptTemplate: {e}"
            current_errors.append(error_msg)
            print(error_msg, file=sys.stderr)

        try:
            self._output_parser = StrOutputParser()
        except Exception as e:
            error_msg = f"Error creating StrOutputParser: {e}"
            current_errors.append(error_msg)
            print(error_msg, file=sys.stderr)

        self._chain_with_memory_and_rag = self._build_chain_prefix()
        if not self._chain_with_memory_and_rag and "Error building chain prefix" not in "".join(current_errors):
            current_errors.append("Failed to build chain prefix for memory and RAG.")

        if current_errors: # Store combined errors from component initialization
            self.initialization_error = "\n".join(current_errors)

        # Attempt to build the full chain
        if not self._rebuild_chain_with_current_llm() and not self.initialization_error:
            # If rebuild failed but no specific error was captured yet from component init
            self.initialization_error = (self.initialization_error + "\n" if self.initialization_error else "") + "Initial chain construction failed."

        if self.initialization_error:
            print(f"LangchainPipelineManager initialization issues: {self.initialization_error}", file=sys.stderr)


    def update_llm_and_rebuild_chain(self, new_ollama_url: str, new_model_name: str) -> Tuple[bool, bool]:
        """
        Updates the LLM and rebuilds the chain.
        Returns:
            Tuple (requested_update_succeeded: bool, operational_status_ok: bool)
            - requested_update_succeeded: True if the NEW model was set up correctly.
            - operational_status_ok: True if ANY valid LLM and chain are active (new or reverted old).
        """
        print(f"Attempting to update LLM to model: {new_model_name} at URL: {new_ollama_url}", file=sys.stdout)

        # Store current valid LLM as previous before attempting update
        if self.llm:
            self._previous_llm = self.llm
            # It might be good to also store previous_model_name and previous_ollama_url if needed for logging reverts
        
        original_initialization_error = self.initialization_error # Preserve pre-update error state

        try:
            self.llm = ChatOllama(model=new_model_name, base_url=str(new_ollama_url))
            self.current_model_name = new_model_name
            self.current_ollama_url = new_ollama_url
            print(f"Successfully created new LLM instance: {new_model_name}", file=sys.stdout)

            if self._rebuild_chain_with_current_llm():
                print(f"Successfully updated and rebuilt chain with NEW model: {new_model_name}", file=sys.stdout)
                self.initialization_error = None # Clear errors if new setup is fine
                return True, True # Requested update succeeded, operational status is OK
            else:
                # New LLM created, but chain rebuild failed with new LLM
                error_msg_specific = f"Failed to rebuild chain with NEW model {new_model_name}. "
                print(error_msg_specific, file=sys.stderr)
                # initialization_error is already set by _rebuild_chain_with_current_llm
                # Attempt to revert
                if self._previous_llm:
                    print(f"Attempting to revert to previous LLM: {self._previous_llm.model}", file=sys.stdout)
                    self.llm = self._previous_llm
                    # Update current_model_name and current_ollama_url if you stored them for the previous LLM
                    # For simplicity, assuming self._previous_llm.model and self._previous_llm.base_url are accessible
                    self.current_model_name = getattr(self._previous_llm, 'model', 'previous_model')
                    self.current_ollama_url = getattr(self._previous_llm, 'base_url', 'previous_url')

                    if self._rebuild_chain_with_current_llm():
                        revert_msg = f"Reverted to previous LLM ({self.current_model_name}) and rebuilt chain."
                        print(revert_msg, file=sys.stdout)
                        self.initialization_error = error_msg_specific + revert_msg # Prepend specific failure, add revert info
                        return False, True # Requested update failed, but operational with old model
                    else:
                        critical_error = error_msg_specific + f"Revert to previous LLM ({self.current_model_name}) also failed to rebuild chain."
                        print(critical_error, file=sys.stderr)
                        self.initialization_error = critical_error
                        self.llm = None # No usable LLM
                        self.chain = None
                        return False, False # Requested update failed, and not operational
                else:
                    # No previous LLM to revert to
                    self.initialization_error = error_msg_specific + "No previous LLM to revert to."
                    print(self.initialization_error, file=sys.stderr)
                    self.llm = None
                    self.chain = None
                    return False, False # Requested update failed, and not operational

        except Exception as e:
            # Failed to even create the new ChatOllama instance
            error_msg_specific = f"Error creating NEW LLM instance {new_model_name}: {e}. "
            print(error_msg_specific, file=sys.stderr)
            # Attempt to revert
            if self._previous_llm:
                print(f"Attempting to revert to previous LLM: {self._previous_llm.model}", file=sys.stdout)
                self.llm = self._previous_llm
                self.current_model_name = getattr(self._previous_llm, 'model', 'previous_model')
                self.current_ollama_url = getattr(self._previous_llm, 'base_url', 'previous_url')

                if self._rebuild_chain_with_current_llm():
                    revert_msg = f"Reverted to previous LLM ({self.current_model_name}) and rebuilt chain."
                    print(revert_msg, file=sys.stdout)
                    self.initialization_error = error_msg_specific + revert_msg
                    return False, True # Requested update failed, but operational with old model
                else:
                    critical_error = error_msg_specific + f"Revert to previous LLM ({self.current_model_name}) also failed to rebuild chain."
                    print(critical_error, file=sys.stderr)
                    self.initialization_error = critical_error
                    self.llm = None
                    self.chain = None
                    return False, False # Requested update failed, and not operational
            else:
                # No previous LLM to revert to
                self.initialization_error = error_msg_specific + "No previous LLM to revert to."
                print(self.initialization_error, file=sys.stderr)
                self.llm = None
                self.chain = None
                return False, False # Requested update failed, and not operational


    async def invoke_chain(self, user_prompt: str, conversation_id: Optional[str]) -> str:
        if not self.chain:
            if not self._rebuild_chain_with_current_llm(): # Try to rebuild if chain is None
                 error_msg = self.initialization_error or "Langchain chain is not initialized and cannot be rebuilt."
                 print(f"Chain invocation failed: {error_msg}", file=sys.stderr)
                 raise RuntimeError(error_msg)

        # If self.chain is still None after attempt to rebuild, error was set by _rebuild_chain_with_current_llm
        if not self.chain:
             raise RuntimeError(self.initialization_error or "Chain is None after rebuild attempt.")

        try:
            response_content = await self.chain.ainvoke({
                "user_prompt": user_prompt,
                "conversation_id": conversation_id
            })
            return response_content
        except Exception as e:
            print(f"Error during chain.ainvoke: {e}", file=sys.stderr)
            raise RuntimeError(f"Error during Langchain chain invocation: {e}")


    def get_status(self) -> tuple[str, str | None]:
        if self.chain and self.llm: # If chain and llm are operational
            if self.initialization_error: # But there was some non-critical error (e.g. requested update failed but reverted)
                return "degraded", self.initialization_error
            return "ok", f"Langchain pipeline operational with model: {self.current_model_name or 'unknown'}."

        # If chain or llm is not operational
        error_message = self.initialization_error or "Langchain pipeline components not fully initialized or failed."
        return "error", error_message

# Initialize a global instance
langchain_pipeline_manager = LangchainPipelineManager()
