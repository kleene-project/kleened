import Config

config :logger, :default_formatter,
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
     }
   }}
]

config :kleened, env: Mix.env()
