#!/usr/bin/env python3
"""
gsplat Training Script

This script provides a command-line interface for training 3D Gaussian Splatting models
using the gsplat library. It serves as the training interface called by the gsplat backend.

Requirements:
    - Python 3.8+
    - gsplat library: pip install gsplat
    - PyTorch with CUDA support
    - COLMAP reconstruction data

Usage:
    python gsplat_train.py --data <images_dir> --colmap-dir <colmap_sparse_dir> \
        --model-dir <output_dir> --iterations 30000

Environment Variables:
    GSPLAT_BIN: Can be set to this script path (e.g., "scripts/gsplat_train.py")
    GSPLAT_PYTHON: Python interpreter to use (default: "python3")
"""

import argparse
import os
import sys
from pathlib import Path


def parse_args():
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Train 3D Gaussian Splatting model using gsplat"
    )
    
    # Required arguments
    parser.add_argument(
        "--data",
        type=Path,
        required=True,
        help="Path to images directory",
    )
    parser.add_argument(
        "--colmap-dir",
        type=Path,
        required=True,
        help="Path to COLMAP sparse reconstruction directory",
    )
    parser.add_argument(
        "--model-dir",
        type=Path,
        required=True,
        help="Output directory for trained model",
    )
    
    # Training parameters
    parser.add_argument(
        "--iterations",
        type=int,
        default=30000,
        help="Number of training iterations (default: 30000)",
    )
    parser.add_argument(
        "--sh-degree",
        type=int,
        default=3,
        help="Spherical harmonics degree (default: 3)",
    )
    
    # Densification parameters
    parser.add_argument(
        "--densify-grad-thresh",
        type=float,
        default=0.0002,
        help="Gradient threshold for densification (default: 0.0002)",
    )
    parser.add_argument(
        "--densify-start-iter",
        type=int,
        default=500,
        help="Start densification at iteration (default: 500)",
    )
    parser.add_argument(
        "--densify-stop-iter",
        type=int,
        default=15000,
        help="Stop densification at iteration (default: 15000)",
    )
    parser.add_argument(
        "--densify-every",
        type=int,
        default=100,
        help="Densify every N iterations (default: 100)",
    )
    
    # Opacity reset
    parser.add_argument(
        "--reset-opacity-every",
        type=int,
        default=3000,
        help="Reset opacity every N iterations (default: 3000)",
    )
    
    # Output format
    parser.add_argument(
        "--save-ply",
        action="store_true",
        help="Save model in PLY format",
    )
    
    return parser.parse_args()


def validate_inputs(args):
    """Validate input paths and parameters."""
    if not args.data.exists():
        print(f"Error: Images directory does not exist: {args.data}", file=sys.stderr)
        sys.exit(1)
    
    if not args.colmap_dir.exists():
        print(f"Error: COLMAP directory does not exist: {args.colmap_dir}", file=sys.stderr)
        sys.exit(1)
    
    # Check for required COLMAP files
    required_files = ["cameras.bin", "images.bin", "points3D.bin"]
    for filename in required_files:
        filepath = args.colmap_dir / filename
        if not filepath.exists():
            print(f"Error: Required COLMAP file not found: {filepath}", file=sys.stderr)
            sys.exit(1)
    
    # Create output directory
    args.model_dir.mkdir(parents=True, exist_ok=True)


def read_binary_array(file, dtype, shape):
    """Read binary array from file."""
    import numpy as np
    count = np.prod(shape) if isinstance(shape, (list, tuple)) else shape
    data = np.fromfile(file, dtype=dtype, count=count)
    return data.reshape(shape) if isinstance(shape, (list, tuple)) else data


def load_colmap_data(colmap_dir, images_dir):
    """Load COLMAP reconstruction data."""
    import numpy as np
    import struct
    from PIL import Image
    
    cameras = {}
    images = {}
    points3D = []
    
    # Load cameras.bin
    cameras_file = colmap_dir / "cameras.bin"
    with open(cameras_file, "rb") as f:
        num_cameras = struct.unpack("Q", f.read(8))[0]
        # COLMAP camera model parameter counts
        CAMERA_MODEL_NUM_PARAMS = {
            0: 3,  # SIMPLE_PINHOLE: f, cx, cy
            1: 4,  # PINHOLE: fx, fy, cx, cy
            2: 4,  # SIMPLE_RADIAL: f, cx, cy, k1
            3: 5,  # RADIAL: f, cx, cy, k1, k2
            4: 8,  # OPENCV: fx, fy, cx, cy, k1, k2, p1, p2
            5: 12, # OPENCV_FISHEYE: fx, fy, cx, cy, k1, k2, k3, k4, ...
            6: 5,  # FULL_OPENCV: fx, fy, cx, cy, k1 (partial)
            7: 12, # FOV
            8: 4,  # SIMPLE_RADIAL_FISHEYE
            9: 5,  # RADIAL_FISHEYE
            10: 5, # THIN_PRISM_FISHEYE
        }
        for _ in range(num_cameras):
            camera_id = struct.unpack("I", f.read(4))[0]
            model_id = struct.unpack("i", f.read(4))[0]
            width = struct.unpack("Q", f.read(8))[0]
            height = struct.unpack("Q", f.read(8))[0]
            num_params = CAMERA_MODEL_NUM_PARAMS.get(model_id, 4)
            params = read_binary_array(f, np.float64, num_params)
            
            cameras[camera_id] = {
                "id": camera_id,
                "model": model_id,
                "width": width,
                "height": height,
                "params": params,
            }
    
    # Load images.bin
    images_file = colmap_dir / "images.bin"
    with open(images_file, "rb") as f:
        num_images = struct.unpack("Q", f.read(8))[0]
        for _ in range(num_images):
            image_id = struct.unpack("I", f.read(4))[0]
            qvec = read_binary_array(f, np.float64, 4)
            tvec = read_binary_array(f, np.float64, 3)
            camera_id = struct.unpack("I", f.read(4))[0]
            
            # Read image name (null-terminated string)
            name_bytes = b""
            while True:
                char = f.read(1)
                if char == b"\x00":
                    break
                name_bytes += char
            image_name = name_bytes.decode("utf-8")
            
            # Read points2D (skip for now)
            num_points2D = struct.unpack("Q", f.read(8))[0]
            f.seek(24 * num_points2D, 1)  # Skip points2D data
            
            # Load actual image
            image_path = images_dir / image_name
            if image_path.exists():
                img = Image.open(image_path)
                img_array = np.array(img, dtype=np.float32) / 255.0
            else:
                # Use placeholder if image not found
                camera = cameras[camera_id]
                img_array = np.zeros((camera["height"], camera["width"], 3), dtype=np.float32)
            
            images[image_id] = {
                "id": image_id,
                "qvec": qvec,
                "tvec": tvec,
                "camera_id": camera_id,
                "name": image_name,
                "image": img_array,
            }
    
    # Load points3D.bin
    points_file = colmap_dir / "points3D.bin"
    with open(points_file, "rb") as f:
        num_points = struct.unpack("Q", f.read(8))[0]
        for _ in range(num_points):
            point_id = struct.unpack("Q", f.read(8))[0]
            xyz = read_binary_array(f, np.float64, 3)
            rgb = read_binary_array(f, np.uint8, 3)
            error = struct.unpack("d", f.read(8))[0]
            
            # Read track (skip)
            track_length = struct.unpack("Q", f.read(8))[0]
            f.seek(8 * track_length, 1)  # Skip track data
            
            points3D.append({
                "xyz": xyz.astype(np.float32),
                "rgb": rgb.astype(np.float32) / 255.0,
            })
    
    return cameras, images, points3D


def initialize_gaussians(points3D, device):
    """Initialize Gaussian parameters from COLMAP point cloud."""
    import torch
    import numpy as np
    
    num_points = len(points3D)
    
    # Extract positions and colors
    positions = np.array([p["xyz"] for p in points3D], dtype=np.float32)
    colors = np.array([p["rgb"] for p in points3D], dtype=np.float32)
    
    # Initialize parameters
    means = torch.tensor(positions, device=device, requires_grad=True)
    
    # Initialize scales (log space, small initial values)
    scales = torch.log(torch.ones(num_points, 3, device=device) * 0.01)
    scales.requires_grad = True
    
    # Initialize rotations (quaternions, identity rotation)
    quats = torch.tensor([[1.0, 0.0, 0.0, 0.0]] * num_points, device=device, requires_grad=True)
    
    # Initialize opacities (inverse sigmoid space)
    opacities = torch.logit(torch.ones(num_points, 1, device=device) * 0.1)
    opacities.requires_grad = True
    
    # Initialize spherical harmonics (RGB colors)
    # SH degree 0 (DC component) from point colors
    sh_degree = 3
    sh_dim = (sh_degree + 1) ** 2
    shs = torch.zeros(num_points, sh_dim, 3, device=device, requires_grad=True)
    
    # Set DC component from colors
    # DC component is at index 0, needs to be scaled
    C0 = 0.28209479177387814  # sqrt(1/(4*pi))
    with torch.no_grad():
        shs[:, 0, :] = torch.tensor(colors, device=device) / C0
    
    return {
        "means": means,
        "scales": scales,
        "quats": quats,
        "opacities": opacities,
        "sh_coeffs": shs,
    }


def setup_optimizers(gaussians, args):
    """Setup optimizers for different Gaussian parameters."""
    import torch
    
    optimizers = {
        "means": torch.optim.Adam([gaussians["means"]], lr=1.6e-4),
        "scales": torch.optim.Adam([gaussians["scales"]], lr=5e-3),
        "quats": torch.optim.Adam([gaussians["quats"]], lr=1e-3),
        "opacities": torch.optim.Adam([gaussians["opacities"]], lr=5e-2),
        "sh_coeffs": torch.optim.Adam([gaussians["sh_coeffs"]], lr=2.5e-3),
    }
    
    return optimizers


def qvec_to_rotmat(qvec):
    """Convert quaternion to rotation matrix."""
    import numpy as np
    
    qvec = qvec / np.linalg.norm(qvec)
    w, x, y, z = qvec
    
    return np.array([
        [1 - 2*y*y - 2*z*z, 2*x*y - 2*w*z, 2*x*z + 2*w*y],
        [2*x*y + 2*w*z, 1 - 2*x*x - 2*z*z, 2*y*z - 2*w*x],
        [2*x*z - 2*w*y, 2*y*z + 2*w*x, 1 - 2*x*x - 2*y*y],
    ])


def train_model(gaussians, optimizers, cameras, images, args, device):
    """Main training loop."""
    import torch
    import numpy as np
    from gsplat import rasterization
    import time
    
    image_ids = list(images.keys())
    num_images = len(image_ids)
    
    densify_grads = []
    
    print(f"  Training with {num_images} images")
    start_time = time.time()
    
    for iteration in range(1, args.iterations + 1):
        # Sample random image
        image_id = image_ids[np.random.randint(0, num_images)]
        image_data = images[image_id]
        camera = cameras[image_data["camera_id"]]
        
        # Get camera parameters
        width, height = camera["width"], camera["height"]
        fx, fy, cx, cy = camera["params"][:4]
        
        # Get camera pose (world to camera)
        qvec = image_data["qvec"]
        tvec = image_data["tvec"]
        R = qvec_to_rotmat(qvec)
        T = tvec
        
        # Convert to camera-to-world for rendering
        c2w = np.eye(4)
        c2w[:3, :3] = R.T
        c2w[:3, 3] = -R.T @ T
        
        viewmat = torch.tensor(np.linalg.inv(c2w), dtype=torch.float32, device=device)
        
        # Create projection matrix
        K = torch.tensor([
            [fx, 0, cx],
            [0, fy, cy],
            [0, 0, 1],
        ], dtype=torch.float32, device=device)
        
        # Ground truth image
        gt_image = torch.tensor(image_data["image"], device=device)
        
        # Render
        try:
            rendered = rasterization(
                means=gaussians["means"],
                quats=gaussians["quats"],
                scales=torch.exp(gaussians["scales"]),
                opacities=torch.sigmoid(gaussians["opacities"]).squeeze(-1),  # [N, 1] -> [N]
                colors=gaussians["sh_coeffs"][:, 0, :],  # Use DC component only for simplicity
                viewmats=viewmat[None, ...],
                Ks=K[None, ...],
                width=width,
                height=height,
            )
            
            rendered_image = rendered[0].permute(1, 2, 0)  # CHW -> HWC
            
        except Exception as e:
            print(f"Warning: Rendering failed at iteration {iteration}: {e}")
            continue
        
        # Compute loss (L1 + SSIM would be better, but L1 for simplicity)
        loss = torch.abs(rendered_image - gt_image).mean()
        
        # Backward pass
        loss.backward()
        
        # Store gradients for densification
        if iteration >= args.densify_start_iter and iteration <= args.densify_stop_iter:
            with torch.no_grad():
                if gaussians["means"].grad is not None:
                    grad_norm = torch.norm(gaussians["means"].grad, dim=1, keepdim=True)
                    densify_grads.append(grad_norm.detach())
        
        # Optimizer step
        for opt in optimizers.values():
            opt.step()
            opt.zero_grad()
        
        # Densification
        if iteration >= args.densify_start_iter and iteration <= args.densify_stop_iter:
            if iteration % args.densify_every == 0:
                densify_gaussians(gaussians, densify_grads, args.densify_grad_thresh, optimizers)
                densify_grads = []
        
        # Opacity reset
        if args.reset_opacity_every > 0 and iteration % args.reset_opacity_every == 0:
            with torch.no_grad():
                gaussians["opacities"].fill_(-2.0)  # Reset to low opacity in logit space
        
        # Logging
        if iteration % 1000 == 0 or iteration == args.iterations:
            elapsed = time.time() - start_time
            print(f"  Step {iteration}: loss={loss.item():.6f}, "
                  f"gaussians={gaussians['means'].shape[0]}, "
                  f"time={elapsed:.1f}s")


def densify_gaussians(gaussians, grad_history, threshold, optimizers):
    """Adaptive densification based on gradients."""
    import torch
    
    if len(grad_history) == 0:
        return
    
    # Average gradients
    avg_grads = torch.stack(grad_history).mean(dim=0)
    
    # Find gaussians with high gradients
    mask = (avg_grads > threshold).squeeze()
    
    if mask.sum() == 0:
        return
    
    # Clone high-gradient gaussians
    with torch.no_grad():
        for key in gaussians:
            selected = gaussians[key][mask]
            gaussians[key] = torch.cat([gaussians[key], selected], dim=0)
            gaussians[key].requires_grad = True
    
    # Recreate optimizers with new parameters
    import torch.optim as optim
    optimizers["means"] = optim.Adam([gaussians["means"]], lr=1.6e-4)
    optimizers["scales"] = optim.Adam([gaussians["scales"]], lr=5e-3)
    optimizers["quats"] = optim.Adam([gaussians["quats"]], lr=1e-3)
    optimizers["opacities"] = optim.Adam([gaussians["opacities"]], lr=5e-2)
    optimizers["sh_coeffs"] = optim.Adam([gaussians["sh_coeffs"]], lr=2.5e-3)


def save_model(gaussians, output_dir, save_ply=True):
    """Save trained Gaussian model."""
    import torch
    import numpy as np
    
    if save_ply:
        ply_path = output_dir / "point_cloud.ply"
        
        # Convert to numpy
        means = gaussians["means"].detach().cpu().numpy()
        colors_sh = gaussians["sh_coeffs"].detach().cpu().numpy()
        
        # Convert SH DC component to RGB
        C0 = 0.28209479177387814
        colors = np.clip(colors_sh[:, 0, :] * C0, 0, 1)
        colors = (colors * 255).astype(np.uint8)
        
        # Write PLY file
        with open(ply_path, "w") as f:
            f.write("ply\n")
            f.write("format ascii 1.0\n")
            f.write(f"element vertex {len(means)}\n")
            f.write("property float x\n")
            f.write("property float y\n")
            f.write("property float z\n")
            f.write("property uchar red\n")
            f.write("property uchar green\n")
            f.write("property uchar blue\n")
            f.write("end_header\n")
            
            for i in range(len(means)):
                x, y, z = means[i]
                r, g, b = colors[i]
                f.write(f"{x:.6f} {y:.6f} {z:.6f} {r} {g} {b}\n")
    
    # Save full model checkpoint
    checkpoint_path = output_dir / "checkpoint.pth"
    torch.save({
        "means": gaussians["means"].detach().cpu(),
        "scales": gaussians["scales"].detach().cpu(),
        "quats": gaussians["quats"].detach().cpu(),
        "opacities": gaussians["opacities"].detach().cpu(),
        "sh_coeffs": gaussians["sh_coeffs"].detach().cpu(),
    }, checkpoint_path)


def main():
    """Main training function."""
    args = parse_args()
    validate_inputs(args)
    
    print(f"Starting gsplat training:")
    print(f"  Images: {args.data}")
    print(f"  COLMAP: {args.colmap_dir}")
    print(f"  Output: {args.model_dir}")
    print(f"  Iterations: {args.iterations}")
    
    try:
        # Import required libraries
        try:
            import torch
            import numpy as np
            from gsplat import rasterization
            from pathlib import Path
            import struct
        except ImportError as e:
            print(
                f"Error: Required library not found: {e}",
                file=sys.stderr,
            )
            print("Install with: pip install gsplat torch numpy", file=sys.stderr)
            sys.exit(1)
        
        # Check CUDA availability
        if not torch.cuda.is_available():
            print("Warning: CUDA not available. Training will be very slow on CPU.", file=sys.stderr)
            device = torch.device("cpu")
        else:
            device = torch.device("cuda")
            print(f"Using CUDA device: {torch.cuda.get_device_name(0)}")
        
        # Load COLMAP reconstruction
        print("\n[1/4] Loading COLMAP reconstruction...")
        cameras, images, points3D = load_colmap_data(args.colmap_dir, args.data)
        
        if len(images) == 0:
            print("Error: No images found in COLMAP reconstruction", file=sys.stderr)
            sys.exit(1)
        
        if len(points3D) == 0:
            print("Error: No 3D points found in COLMAP reconstruction", file=sys.stderr)
            sys.exit(1)
        
        print(f"  Loaded {len(cameras)} cameras, {len(images)} images, {len(points3D)} 3D points")
        
        # Initialize Gaussian parameters from point cloud
        print("\n[2/4] Initializing Gaussian Splatting model...")
        gaussians = initialize_gaussians(points3D, device)
        print(f"  Initialized {gaussians['means'].shape[0]} Gaussians")
        
        # Setup optimizers
        optimizers = setup_optimizers(gaussians, args)
        
        # Training loop
        print(f"\n[3/4] Training for {args.iterations} iterations...")
        train_model(
            gaussians=gaussians,
            optimizers=optimizers,
            cameras=cameras,
            images=images,
            args=args,
            device=device,
        )
        
        # Save trained model
        print("\n[4/4] Saving trained model...")
        save_model(gaussians, args.model_dir, args.save_ply)
        print(f"  Model saved to: {args.model_dir}")
        
        return 0
        
    except Exception as e:
        print(f"Error during training: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        return 1


if __name__ == "__main__":
    sys.exit(main())
