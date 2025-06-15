# filename: Utils/langchain_components.py
import sys
from typing import Optional, Dict, Any

from langchain_ollama.chat_models import ChatOllama
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import StrOutputParser
from langchain_core.runnables import RunnableSerializable

from ..config import OLLAMA_MODEL, OLLAMA_BASE_URL


class LangchainPipelineManager:
    """
    Manages the Langchain LLM, prompt, and the main processing chain.
    MODIFIED: This manager now uses a much simpler, more direct prompt template.
    """

    def __init__(self):
        self.llm: Optional[ChatOllama] = None
        self._previous_llm: Optional[ChatOllama] = None
        self.current_model_name: Optional[str] = None
        self.current_ollama_url: Optional[str] = None
        self.prompt_template: Optional[ChatPromptTemplate] = None
        self.chain: Optional[RunnableSerializable[Dict, str]] = None
        self.initialization_error: Optional[str] = None
        self._output_parser: Optional[StrOutputParser] = None
        self._initialize_components()

    def _rebuild_chain_with_current_llm(self) -> bool:
        """Attempts to rebuild the chain with the current self.llm and other components."""
        if self.llm and self.prompt_template and self._output_parser:
            try:
                self.chain = self.prompt_template | self.llm | self._output_parser
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

        # FIXED: The prompt template is now much simpler. The service layer will be responsible
        # for dynamically building the content of the `system_prompt`.
        self.prompt_template = ChatPromptTemplate.from_messages([
            ("system", "{system_prompt}"),
            ("user", "{user_prompt}")
        ])
        self._output_parser = StrOutputParser()
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

    async def invoke_chain(
        self,
        user_prompt: str,
        system_prompt: str, # MODIFIED: Accepts the fully formed system prompt
    ) -> str:
        """
        MODIFIED: Invokes the chain with a dynamically constructed system prompt.
        """
        if not self.chain:
            if not self._rebuild_chain_with_current_llm():
                error_msg = self.initialization_error or "Chain is not initialized and cannot be rebuilt."
                raise RuntimeError(error_msg)

        if not self.chain:
            raise RuntimeError(self.initialization_error or "Chain is None after rebuild attempt.")

        try:
            print("[LangchainPipeline] Invoking the simplified LLM chain...", file=sys.stdout)
            response_content = await self.chain.ainvoke({
                "user_prompt": user_prompt,
                "system_prompt": system_prompt
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
