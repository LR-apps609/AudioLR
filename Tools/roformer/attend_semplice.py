# Attenzione «a mano» (prodotto scalare, softmax, media pesata): stesso risultato di
# F.scaled_dot_product_attention, ma in operazioni che Core ML converte sempre.
import torch
from torch import nn


class Attend(nn.Module):
    def __init__(self, dropout=0.0, flash=False, scale=None):
        super().__init__()
        self.scale = scale

    def forward(self, q, k, v):
        scale = self.scale if self.scale is not None else q.shape[-1] ** -0.5
        sim = torch.matmul(q, k.transpose(-1, -2)) * scale
        return torch.matmul(sim.softmax(dim=-1), v)
