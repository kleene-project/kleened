# Dialyzer warnings that are currently suppressed.
#
# `list_unused_filters: true` is set in mix.exs, so a filter that no longer
# matches any warning fails the run. That is intentional -- it stops this file
# from silently rotting the way its Amnesia-era predecessor did, and it means
# fixing one of the issues below forces you to delete its entry here.
#
# ---------------------------------------------------------------------------
# THIS IS A DEBT LIST, NOT AN ALLOWLIST.
#
# Every entry below is a *pre-existing* finding from the first run of dialyzer
# against this project. None of them are typespec problems -- the specs are
# consistent with the code -- they are unreachable clauses, functions that can
# only raise, and calls that cannot succeed. They are suppressed so that the
# CI gate is meaningful for new code; they should be triaged and burned down.
#
# Verifying a fix for most of these requires the FreeBSD VM, since they sit in
# jail/ZFS/pf code paths that cannot be exercised on a Linux host.
# ---------------------------------------------------------------------------
[
  # --- Error clauses that can never be reached -----------------------------
  #
  # In each case the callee never returns the error shape the caller matches
  # on, so a genuine failure would raise CaseClauseError instead of being
  # handled. The most clear-cut is in add_container_ipnet_alias/4, which
  # matches `{:errro, reason}` -- a typo for `:error`.
  {"lib/core/network.ex",
   "The pattern can never match the type {:error, <<_::64, _::size(8)>>}."},
  {"lib/core/network.ex", "The pattern can never match the type {:running, false}."},
  {"lib/core/exec.ex", "The pattern can never match the type {:error, <<_::64, _::size(8)>>}."},
  {"lib/core/exec.ex",
   "The pattern can never match the type {:error, <<_::152, _::size(288)>>}."},
  {"lib/core/exec.ex", "The pattern can never match the type binary()."},
  {"lib/core/exec.ex", "The pattern can never match the type [<<_::8, _::size(1)>>], [
  {:gateway, {_, _}} | {:gateway6, {_, _}} | {:subnet, {_, _, _}} | {:subnet6, {_, _, _}}
]."},
  {"lib/core/image.ex", "The pattern can never match the type :error | {:error, binary()}."},
  {"lib/api/container.ex",
   "The pattern can never match the type {:error, :is_running | :not_found}."},
  {"lib/api/container.ex",
   "The pattern can never match the type {:error, <<_::64, _::size(8)>>}."},
  {"lib/api/container.ex",
   "The pattern can never match the type %Plug.Conn.Unfetched{:aspect => atom(), binary() => _}."},
  {"lib/api/image_build.ex",
   "The pattern can never match the type {:build, {:error, <<_::64, _::size(8)>>}}."},

  # --- Dead branches -------------------------------------------------------
  #
  # get_routing_table/1 has an :ipv6 clause but is only ever called with :ipv4.
  {"lib/core/freebsd.ex", "The pattern can never match the type :ipv4."},

  # --- Functions that can only raise, and their callers --------------------
  #
  # These bottom out in config_error/1 or init_error/1 (both no_return), or in
  # a match that cannot succeed. Dialyzer reports the function and, separately,
  # every call site.
  {"lib/core/image.ex", "Function assemble_and_save_image/1 has no local return."},
  {"lib/core/image.ex", "The function call delete_container will not succeed."},
  {"lib/core/exec.ex", "Function jexec_start_container/2 has no local return."},
  {"lib/core/exec.ex", "Function jail_start_container/3 has no local return."},
  {"lib/api/container.ex", "Function create/2 has no local return."},
  {"lib/api/container.ex", "Function update/2 has no local return."},
  {"lib/api/container.ex", "The function call update will not succeed."},
  {"lib/api/exec.ex", "Function create/2 has no local return."},
  {"lib/api/exec.ex", "The function call create will not succeed."},
  {"lib/api/network.ex", "Function create/2 has no local return."},
  {"lib/api/network.ex", "The function call create will not succeed."},
  {"lib/api/network.ex", "Function connect/2 has no local return."},
  {"lib/api/network.ex", "The function call connect will not succeed."},

  # --- Opaque type misuse --------------------------------------------------
  #
  # initialize_logging/1 calls Enum.member? on a value dialyzer sees as opaque.
  {"lib/core/config.ex", "Type mismatch in call without opaque term in member?."},

  # ZFS.info/1 returns atom keys; this clause matches the string key
  # "mountpoint", so the "no mountpoint" branch is dead.
  {"lib/core/config.ex",
   "The pattern can never match the type %{:exists? => boolean(), :mountpoint => nil | binary()}."}
]
