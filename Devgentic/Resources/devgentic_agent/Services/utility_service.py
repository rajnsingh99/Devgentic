# filename: Services/utility_service.py
from typing import List, Dict, Any


class UtilityService:
    """
    Provides utility functions such as listing models from providers.
    """

    def list_remote_models(self, provider: str, api_key: str) -> List[Dict[str, Any]]:
        """
        Fetches the list of available models from a remote provider.
        """
        model_list = []
        if provider == "openai":
            try:
                from openai import OpenAI
                client = OpenAI(api_key=api_key)
                models = client.models.list()
                model_list = [{"id": model.id, "owned_by": model.owned_by} for model in models.data]
            except ImportError:
                raise RuntimeError("openai package is not installed. Please run 'pip install openai'")
            except Exception as e:
                raise RuntimeError(f"Failed to fetch models from OpenAI: {e}")

        elif provider == "google":
            try:
                import google.generativeai as genai
                genai.configure(api_key=api_key)
                models = genai.list_models()
                for m in models:
                    # Filter for models that support the 'generateContent' method
                    if 'generateContent' in m.supported_generation_methods:
                        model_list.append({"id": m.name, "display_name": m.display_name})
            except ImportError:
                raise RuntimeError(
                    "google-generativeai package is not installed. Please run 'pip install google-generativeai'")
            except Exception as e:
                raise RuntimeError(f"Failed to fetch models from Google: {e}")

        elif provider == "anthropic":
            # Anthropic does not have a public model listing API via their client library
            # We will return a static list of common models.
            model_list = [
                {"id": "claude-3-opus-20240229"},
                {"id": "claude-3-sonnet-20240229"},
                {"id": "claude-3-haiku-20240307"},
                {"id": "claude-2.1"},
            ]

        else:
            raise ValueError(f"Provider '{provider}' is not supported for listing models.")

        return model_list


utility_service = UtilityService()
