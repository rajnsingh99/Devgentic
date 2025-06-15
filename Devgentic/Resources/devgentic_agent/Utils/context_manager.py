# filename: Utils/context_manager.py
import sys
from typing import Optional, Tuple, List

try:
    import tiktoken
except ImportError:
    tiktoken = None
    print("Warning: 'tiktoken' not installed. Context management will be disabled.", file=sys.stderr)

from ..Models.common_models import Alert, Suggestion, Action

class ContextManager:
    """
    A centralized utility to manage the LLM's context window.
    It calculates token counts and determines the appropriate action
    (e.g., truncate, alert, suggest) based on context usage.
    """
    def __init__(self):
        self.tokenizer = None
        if tiktoken:
            try:
                self.tokenizer = tiktoken.get_encoding("cl100k_base")
            except Exception as e:
                print(f"Error initializing tiktoken tokenizer: {e}", file=sys.stderr)
        else:
            print("ContextManager initialized without a tokenizer. Management features are disabled.", file=sys.stderr)

    def _build_suggestion_payload(self) -> Suggestion:
        """Builds the standard suggestion object for when context is nearly full."""
        actions = [
            Action(type="new_chat_with_summary", displayText="Start New Chat with Summary"),
            Action(type="upgrade_llm", displayText="Upgrade LLM for Larger Context")
        ]
        suggested_models = ["llama3:70b", "gpt-4-turbo"]
        return Suggestion(actions=actions, suggested_models=suggested_models)

    def manage_context(
        self,
        full_prompt_text: str,
        user_prompt: str,
        context_window_size: Optional[int]
    ) -> Tuple[str, Optional[Alert], Optional[Suggestion]]:
        """
        Evaluates the prompt against the context window and returns the final prompt
        to use, along with any necessary alerts or suggestions.

        Args:
            full_prompt_text: The complete prompt including history and RAG context.
            user_prompt: The original user query, to be used if history is truncated.
            context_window_size: The token limit of the target LLM.

        Returns:
            A tuple containing:
            - The final prompt to be sent to the LLM.
            - An optional Alert object.
            - An optional Suggestion object.
        """
        alert_payload: Optional[Alert] = None
        suggestion_payload: Optional[Suggestion] = None

        # If tokenizer isn't available or no window size is given, disable management
        if not self.tokenizer or not context_window_size or context_window_size <= 0:
            print("[ContextManager] Warning: Context management disabled. Proceeding with full prompt.", file=sys.stderr)
            return full_prompt_text, None, None

        token_count = len(self.tokenizer.encode(full_prompt_text))
        context_usage = token_count / context_window_size
        final_prompt_to_llm = full_prompt_text

        print(
            f"[ContextManager] Token evaluation: Count={token_count}, Window={context_window_size}, Usage={context_usage:.2%}",
            file=sys.stdout
        )

        if context_usage < 0.8:
            # Context is well within limits, no action needed.
            pass
        elif 0.8 <= context_usage < 1.0:
            # Context is nearing the limit, include a suggestion.
            suggestion_payload = self._build_suggestion_payload()
        else: # context_usage >= 1.0
            # Context has exceeded the limit. Truncate history and add a critical alert.
            final_prompt_to_llm = user_prompt # Fallback to just the user's prompt
            alert_payload = Alert(
                level="critical",
                title="Context Limit Exceeded",
                message="The conversation history is too long. To continue, the oldest messages were not included in this turn. Accuracy may be affected."
            )
            suggestion_payload = self._build_suggestion_payload()

        return final_prompt_to_llm, alert_payload, suggestion_payload

# Create a singleton instance for reuse
context_manager = ContextManager()
