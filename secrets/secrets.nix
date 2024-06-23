let
  fischer = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPeKDFxgdZlhNXEUx8ex0Fj2Re+tDBvUr52SS4Wh3V9n";
  promox-nixos-infra = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPFMU1iLPsNjj2t3Iaf8OKJNEFkSndTE4LN+f3zCrT8o";
  all = [
    fischer
    promox-nixos-infra
  ];
in
{
  "ssh-bot-priv.age".publicKeys = all;
  "bot-github-token.age".publicKeys = all;
}
