# Rotazioni di posizione (RoPE) calcolate ogni volta dalla lunghezza: niente cache, convertibili in Core ML.
import torch
from rotary_embedding_torch import apply_rotary_emb


def rotate_queries_or_keys(rotary_embed, tensor):
    seq_len = tensor.shape[-2]
    positions = torch.arange(seq_len, dtype=torch.float32, device=tensor.device)
    frequencies = torch.einsum("i,f->if", positions, rotary_embed.freqs.to(torch.float32))
    frequencies = torch.repeat_interleave(frequencies, 2, dim=-1)
    return apply_rotary_emb(frequencies, tensor, seq_dim=-2).to(tensor.dtype)
