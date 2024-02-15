import Config
require Logger

# NOTE The Logger-configuration uses and old format (Elixir 1.14.5).
# Should be updated with Elixir 1.15.x or 1.16.x when the port is updated.

config :logger, :console,
  format: "$time [$level] $metadata:$message\n",
  metadata: [:pid, :file]

config :kleened, :logger, [
  {:handler, :file_log, :logger_std_h,
   %{
     config: %{
       file: ~c"/var/log/kleened.log",
       filesync_repeat_interval: 5000,
       file_check: 5000,
       max_no_bytes: 10_000_000,
       max_no_files: 5,
       compress_on_rotate: false
     },
     format: "$time $file [$level] $metadata:$message\n",
     metadata: [:pid, :file]
   }}
]

config :kleened, env: Mix.env()
