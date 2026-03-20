"""CUDA / gsplat environment verification.

Performs a lightweight check that the GPU, PyTorch CUDA runtime,
and gsplat library are functional on this device.  Mirrors the
checks done by the Rust preflight binary (`3dgs-preflight`).
"""

from __future__ import annotations

import subprocess
import shutil
import sys
import textwrap


# ── helpers ──────────────────────────────────────────────────────────────────

def _ok(label: str, detail: str) -> None:
    print(f"  ✓ {label:<16} {detail}")


def _fail(label: str, detail: str) -> None:
    print(f"  ✗ {label:<16} {detail}")


def _heading(title: str) -> None:
    print(f"\n{title}")
    print("─" * len(title))


def _cmd_version(cmd: str, args: list[str] | None = None) -> str | None:
    """Run *cmd* with *args* and return the first line of stdout, or None."""
    exe = shutil.which(cmd)
    if exe is None:
        return None
    try:
        r = subprocess.run(
            [exe] + (args or ["--version"]),
            capture_output=True,
            text=True,
            timeout=10,
        )
        if r.returncode == 0:
            return (r.stdout.strip() or r.stderr.strip()).splitlines()[0]
    except Exception:
        pass
    return None


# ── individual checks ────────────────────────────────────────────────────────

def _nvidia_smi_info() -> tuple[str | None, float | None]:
    """Use nvidia-smi to get device name and VRAM (works even when PyTorch
    doesn't support the arch)."""
    try:
        r = subprocess.run(
            ["nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if r.returncode == 0:
            parts = r.stdout.strip().split(",")
            name = parts[0].strip() if len(parts) >= 1 else None
            vram = None
            if len(parts) >= 2:
                mib_str = parts[1].strip().replace(" MiB", "")
                try:
                    vram = round(float(mib_str) / 1024.0, 1)
                except ValueError:
                    pass
            return name, vram
    except Exception:
        pass
    return None, None


def check_cuda_gpu() -> dict:
    """Detect CUDA GPU via PyTorch + nvidia-smi fallback.  Returns a report dict."""
    import warnings

    info: dict = {
        "platform": "none",
        "device": None,
        "vram_gb": None,
        "usable": False,
        "torch_version": None,
        "cuda_version": None,
    }

    # Always try nvidia-smi first (works regardless of PyTorch arch support)
    smi_name, smi_vram = _nvidia_smi_info()
    if smi_name:
        info["platform"] = "CUDA"
        info["device"] = smi_name
        info["vram_gb"] = smi_vram

    try:
        import torch  # noqa: E402
    except ImportError:
        return info

    info["torch_version"] = torch.__version__
    info["cuda_version"] = getattr(torch.version, "cuda", None)

    # Suppress noisy "sm_XX is not compatible" warnings during probe
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        cuda_available = torch.cuda.is_available()

    if not cuda_available:
        return info

    info["platform"] = "CUDA"

    # Try to get richer info from torch (may fail on unsupported arch)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        try:
            info["device"] = torch.cuda.get_device_name(0)
        except Exception:
            pass
        try:
            total = torch.cuda.get_device_properties(0).total_mem
            info["vram_gb"] = round(total / (1024**3), 1)
        except Exception:
            pass

    # Quick functional smoke-test: allocate a small tensor on GPU
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            t = torch.zeros(4, 4, device="cuda")
            _ = t @ t  # matrix multiply exercises the CUDA kernel path
            del t
            torch.cuda.empty_cache()
        info["usable"] = True
    except Exception as exc:
        info["usable"] = False
        info["cuda_error"] = str(exc)

    return info


def check_gsplat() -> dict:
    """Verify gsplat can be imported and its CUDA kernels load."""
    info: dict = {"installed": False, "version": None, "kernels_ok": False}

    try:
        import gsplat  # noqa: E402

        info["installed"] = True
        info["version"] = getattr(gsplat, "__version__", "unknown")
    except ImportError:
        return info

    # Exercise the rasterization entry-point with a trivial input so the
    # JIT / pre-compiled CUDA kernels actually get loaded.
    try:
        import torch  # noqa: E402
        from gsplat import rasterization  # noqa: E402

        N = 8  # tiny number of Gaussians
        means = torch.randn(N, 3, device="cuda")
        quats = torch.randn(N, 4, device="cuda")
        quats = quats / quats.norm(dim=-1, keepdim=True)
        scales = torch.rand(N, 3, device="cuda") * 0.1
        opacities = torch.ones(N, device="cuda") * 0.5
        colors = torch.rand(N, 3, device="cuda")

        # Minimal camera: 64×64, identity viewmat
        viewmat = torch.eye(4, device="cuda").unsqueeze(0)
        K = torch.tensor(
            [[64.0, 0.0, 32.0], [0.0, 64.0, 32.0], [0.0, 0.0, 1.0]],
            device="cuda",
        ).unsqueeze(0)

        _rendered, _, _ = rasterization(
            means=means,
            quats=quats,
            scales=scales,
            opacities=opacities,
            colors=colors,
            viewmats=viewmat,
            Ks=K,
            width=64,
            height=64,
        )
        info["kernels_ok"] = True
    except Exception as exc:
        info["kernel_error"] = str(exc)

    return info


# ── main report ──────────────────────────────────────────────────────────────

def main() -> int:
    failures: list[str] = []

    # ── GPU ───────────────────────────────────────────────────────────────
    _heading("CUDA GPU")
    gpu = check_cuda_gpu()
    if gpu["usable"]:
        vram = f"({gpu['vram_gb']}GB VRAM)" if gpu["vram_gb"] else ""
        _ok("CUDA GPU", f"{gpu['device']} {vram}")
    else:
        _fail("CUDA GPU", "not detected or unusable")
        failures.append("No usable CUDA GPU")

    print(f"  {'Platform':<16}: {gpu['platform']}")
    print(f"  {'Device':<16}: {gpu['device'] or 'n/a'}")
    print(f"  {'VRAM':<16}: {gpu['vram_gb'] or 'n/a'} GB")
    print(f"  {'PyTorch':<16}: {gpu['torch_version'] or 'not installed'}")
    print(f"  {'CUDA runtime':<16}: {gpu['cuda_version'] or 'n/a'}")
    print(f"  {'Usable':<16}: {'yes' if gpu['usable'] else 'no'}")

    # ── gsplat ────────────────────────────────────────────────────────────
    _heading("gsplat Library")
    gs = check_gsplat()
    if gs["installed"]:
        _ok("gsplat", f"{gs['version']}")
    else:
        _fail("gsplat", "not installed")
        failures.append("gsplat package not importable")

    if gs.get("kernels_ok"):
        _ok("CUDA kernels", "rasterization smoke-test passed")
    elif gs["installed"]:
        err = gs.get("kernel_error", "unknown")
        # Show only the first line of CUDA errors (the rest is boilerplate)
        short_err = err.splitlines()[0] if err else "unknown"
        _fail("CUDA kernels", f"rasterization failed: {short_err}")
        failures.append(f"gsplat CUDA kernels failed: {short_err}")

    # ── external tools ────────────────────────────────────────────────────
    _heading("External Tools")
    for cmd, args in [
        ("nvidia-smi", ["--version"]),
        ("python3", ["--version"]),
        ("ffmpeg", ["-version"]),
        ("colmap", ["--version"]),
    ]:
        ver = _cmd_version(cmd, args)
        if ver:
            _ok(cmd, ver)
        else:
            _fail(cmd, "not found")

    # ── verdict ───────────────────────────────────────────────────────────
    _heading("Environment Verdict")
    if failures:
        print()
        print("  ❌ ENVIRONMENT CHECK FAILED")
        for f in failures:
            print(f"     • {f}")
        return 1
    else:
        print()
        print("  ✅ ENVIRONMENT CHECK PASSED")
        print("     CUDA and gsplat are functional on this device.")
        return 0


if __name__ == "__main__":
    sys.exit(main())
