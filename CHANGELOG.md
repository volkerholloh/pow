# Changelog

## v1.1.0 (TBA)

### Changes

- Requires Elixir 1.7 or higher
- Requires Ecto 3.0 or higher
- Requires Phoenix 1.4.7 or higher

### Deprecations

- Removed deprecated method `PowResetPassword.Ecto.Context.password_changeset/2`
- Removed deprecated method `Pow.Extension.Config.underscore_extension/1`
- Removed deprecated method `Mix.Pow.context_app/0`
- Removed deprecated method `Mix.Pow.ensure_dep!/3`
- Removed deprecated method `Mix.Pow.context_base/1`
- Removed deprecated method `Mix.Pow.Ecto.Migration.create_migration_files/3`
- Removed deprecated method `Pow.Ecto.Context.repo/1`
- Removed deprecated method `Pow.Ecto.Context.user_schema_mod/1`
- Removed deprecated method `Pow.Plug.get_mod/1`
- Config fallback set with `:messages_backend_fallback` configuration option removed in `Pow.Extension.Phoenix.Controller.Base`
- Removed deprecated Bootstrap support in `Pow.Phoenix.HTML.FormTemplate`
- Removed deprecated module `Pow.Extension.Ecto.Context.Base`
- `:mod` in the `:pow_config` private plug key no longer set in `Pow.Plug.Base`
- Removed deprecated `:persistent_session_cookie_max_age` config option for `PowPersistentSession.Plug.Cookie`
