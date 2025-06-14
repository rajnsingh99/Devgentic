import sys
from typing import Optional, Dict, Any, List, Tuple
from langchain_ollama.chat_models import ChatOllama
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import StrOutputParser
from langchain_core.runnables import RunnablePassthrough, RunnableLambda, RunnableSerializable

from ..config import OLLAMA_MODEL, OLLAMA_BASE_URL
from .conversation_storage_manager import conversation_storage_manager, format_conversation_history_for_prompt
from .vectorstore_client import vector_store_manager, format_chroma_context_for_prompt


class LangchainPipelineManager:
    """
    Manages the Langchain LLM, prompt, and the main processing chain.
    """

    def __init__(self):
        self.llm: Optional[ChatOllama] = None
        self._previous_llm: Optional[ChatOllama] = None
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
        print(f"[LangchainPipeline] Getting chat history for conversation_id: {conversation_id}", file=sys.stdout)

        storage_status, _ = conversation_storage_manager.is_available()
        if storage_status in ["error", "disabled"] or not conversation_id:
            return "Chat history not available."

        raw_history_messages: List[Any] = conversation_storage_manager.get_history(user_id=conversation_id, limit=10)
        formatted_history = format_conversation_history_for_prompt(raw_history_messages)
        print(f"[LangchainPipeline] Retrieved and formatted history:\n---\n{formatted_history}\n---", file=sys.stdout)
        return formatted_history

    def _get_context_from_chroma(self, inputs: Dict[str, Any]) -> str:
        user_prompt = inputs.get("user_prompt")
        print(f"[LangchainPipeline] Getting RAG context for prompt: '{user_prompt[:75]}...'", file=sys.stdout)

        if not vector_store_manager.retriever or not user_prompt:
            return "Context retrieval not available."

        docs = vector_store_manager.retrieve_documents(query=user_prompt)
        formatted_context = format_chroma_context_for_prompt(docs)
        print(f"[LangchainPipeline] Retrieved RAG context:\n---\n{formatted_context}\n---", file=sys.stdout)
        return formatted_context

    def _build_chain_prefix(self) -> Optional[RunnableSerializable[Dict, Dict]]:
        try:
            return RunnablePassthrough.assign(
                chat_history=RunnableLambda(self._get_chat_history),
                context=RunnableLambda(self._get_context_from_chroma)
            )
        except Exception as e:
            self.initialization_error = (self.initialization_error or "") + f"\nError building chain prefix: {e}"
            return None

    def _rebuild_chain_with_current_llm(self) -> bool:
        """Attempts to rebuild the chain with the current self.llm and other components."""
        if self.llm and self.prompt_template and self._chain_with_memory_and_rag and self._output_parser:
            try:
                self.chain = self._chain_with_memory_and_rag | self.prompt_template | self.llm | self._output_parser
                print(f"[LangchainPipeline] Chain successfully rebuilt with LLM: {self.current_model_name}",
                      file=sys.stdout)
                self.initialization_error = None
                return True
            except Exception as e:
                self.initialization_error = (self.initialization_error or "") + f"\nError rebuilding chain: {e}"
                self.chain = None
                return False
        else:
            self.initialization_error = (
                                                    self.initialization_error or "") + "\nCannot rebuild chain: essential components missing."
            self.chain = None
            return False

    def _initialize_components(self):
        try:
            self.current_ollama_url = OLLAMA_BASE_URL
            self.current_model_name = OLLAMA_MODEL
            self.llm = ChatOllama(model=self.current_model_name, base_url=self.current_ollama_url)
            self._previous_llm = self.llm
        except Exception as e:
            self.initialization_error = f"Error initializing LLM: {e}"
            return

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
        self._output_parser = StrOutputParser()
        self._chain_with_memory_and_rag = self._build_chain_prefix()
        self._rebuild_chain_with_current_llm()

    def update_llm_and_rebuild_chain(self, new_ollama_url: str, new_model_name: str):
        if self.llm: self._previous_llm = self.llm
        try:
            self.llm = ChatOllama(model=new_model_name, base_url=str(new_ollama_url))
            self.current_model_name = new_model_name
            self.current_ollama_url = new_ollama_url
            self._rebuild_chain_with_current_llm()
        except Exception as e:
            print(f"Failed to create new LLM instance: {e}. Reverting.", file=sys.stderr)
            self.llm = self._previous_llm
            self._rebuild_chain_with_current_llm()

    async def invoke_chain(self, user_prompt: str, conversation_id: Optional[str]) -> str:
        if not self.chain:
            if not self._rebuild_chain_with_current_llm():
                error_msg = self.initialization_error or "Chain is not initialized and cannot be rebuilt."
                raise RuntimeError(error_msg)

        if not self.chain:
            raise RuntimeError(self.initialization_error or "Chain is None after rebuild attempt.")

        try:
            print("[LangchainPipeline] Invoking the full LLM chain...", file=sys.stdout)
            final_prompt_for_log = self.prompt_template.format(chat_history="<retrieved_history>",
                                                               context="<retrieved_context>", user_prompt=user_prompt)
            print(f"[LangchainPipeline] Final prompt structure being sent to LLM:\n---\n{final_prompt_for_log}\n---",
                  file=sys.stdout)

            response_content = await self.chain.ainvoke({
                "user_prompt": user_prompt,
                "conversation_id": conversation_id
            })
            print("[LangchainPipeline] Chain invocation complete.", file=sys.stdout)
            return response_content
        except Exception as e:
            print(f"Error during chain.ainvoke: {e}", file=sys.stderr)
            raise RuntimeError(f"Error during Langchain chain invocation: {e}")

    def get_status(self) -> tuple[str, str | None]:
        if self.chain and self.llm:
            if self.initialization_error:
                return "degraded", self.initialization_error
            return "ok", f"Langchain pipeline operational with model: {self.current_model_name or 'unknown'}."
        error_message = self.initialization_error or "Pipeline components not fully initialized."
        return "error", error_message


langchain_pipeline_manager = LangchainPipelineManager()
