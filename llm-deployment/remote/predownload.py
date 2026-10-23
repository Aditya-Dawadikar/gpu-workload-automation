"""Download a Hugging Face model into this node's cache before Serve starts it.

Runs on a GPU worker (copied there by scripts/deploy.sh). Fetching up front
shows download errors (gated model, wrong ID) clearly, and replicas then load
from the local cache. Picks the same weight files vLLM would load.
    predownload.py <model-id> [revision]
"""
import os
import sys
import time

from huggingface_hub import HfApi, snapshot_download
from huggingface_hub.utils import GatedRepoError, HfHubHTTPError, RepositoryNotFoundError

# Same preference order vLLM uses when a repo ships several weight formats.
WEIGHT_PATTERNS = ("*.safetensors", "*.bin", "*.pt")
CONFIG_PATTERNS = ["*.json", "*.model", "*.txt", "*.tiktoken", "*.jinja", "*.py"]


def main() -> int:
    model = sys.argv[1]
    revision = (sys.argv[2] if len(sys.argv) > 2 else "") or None
    start = time.time()
    try:
        files = HfApi().list_repo_files(model, revision=revision)
        weights = next((p for p in WEIGHT_PATTERNS if any(f.endswith(p[1:]) for f in files)), None)
        if weights is None:
            print(f"ERROR: {model} has no .safetensors/.bin/.pt weights")
            return 1
        print(f"Downloading {model} ({weights} weights)", flush=True)
        path = snapshot_download(model, revision=revision,
                                 allow_patterns=CONFIG_PATTERNS + [weights],
                                 ignore_patterns=["original/*"])
    except GatedRepoError:
        print(f"ERROR: {model} is gated. Accept its license on https://huggingface.co/{model} "
              "and pass a token (HF_TOKEN or --hf-token-file).")
        return 1
    except RepositoryNotFoundError:
        print(f"ERROR: {model} not found on Hugging Face (or it is private and needs a token).")
        return 1
    except HfHubHTTPError as e:
        print(f"ERROR: Hugging Face request failed: {e}")
        return 1

    size = sum(os.path.getsize(os.path.join(root, f))
               for root, _, names in os.walk(path) for f in names)
    print(f"Downloaded {size / 1e9:.1f} GB in {time.time() - start:.0f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
