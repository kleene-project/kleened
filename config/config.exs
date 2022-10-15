import Config

config :logger, :console,
  # format: "$time[$level] $metadata.file:$message\n",
  format: "[$level] $metadata:$message\n",
  metadata: [:pid, :file]

# metadata: [:pid, :mfa]
