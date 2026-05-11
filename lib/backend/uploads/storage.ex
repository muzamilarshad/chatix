defmodule Backend.Uploads.Storage do
  @moduledoc false

  @max_upload_bytes Application.compile_env(:backend, :max_upload_bytes, 10 * 1024 * 1024)
  @allowed_content_types Application.compile_env(
                           :backend,
                           :allowed_upload_content_types,
                           [
                             "image/png",
                             "image/jpeg",
                             "image/gif",
                             "image/webp",
                             "application/pdf"
                           ]
                         )
  @allowed_extensions Application.compile_env(
                        :backend,
                        :allowed_upload_extensions,
                        [".png", ".jpg", ".jpeg", ".gif", ".webp", ".pdf"]
                      )

  def max_upload_bytes, do: @max_upload_bytes
  def allowed_content_types, do: @allowed_content_types
  def allowed_extensions, do: @allowed_extensions

  def save_upload(%Plug.Upload{} = upload) do
    with :ok <- validate_upload(upload),
         {:ok, destination_dir} <- ensure_upload_dir(),
         {:ok, storage_name} <- build_storage_name(upload.filename),
         destination_path <- Path.join(destination_dir, storage_name),
         :ok <- File.cp(upload.path, destination_path) do
      {:ok,
       %{
         storage_key: "uploads/#{storage_name}",
         filename: upload.filename,
         content_type: upload.content_type || "application/octet-stream",
         size: File.stat!(destination_path).size
       }}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :save_failed}
    end
  end

  defp validate_upload(%Plug.Upload{path: path, filename: filename, content_type: content_type}) do
    with true <- is_binary(path) and path != "",
         true <- is_binary(filename) and String.trim(filename) != "",
         true <- allowed_extension?(filename),
         true <- allowed_content_type?(content_type),
         {:ok, stat} <- File.stat(path),
         true <- stat.size > 0 and stat.size <= @max_upload_bytes do
      :ok
    else
      false -> {:error, :invalid_upload}
      {:error, :unsupported_media_type} -> {:error, :unsupported_media_type}
      {:ok, _stat} -> {:error, :file_too_large}
      {:error, _reason} -> {:error, :invalid_upload}
      _ -> {:error, :invalid_upload}
    end
  end

  defp ensure_upload_dir do
    upload_dir = Application.get_env(:backend, :upload_dir, default_upload_dir())

    case File.mkdir_p(upload_dir) do
      :ok -> {:ok, upload_dir}
      {:error, _reason} -> {:error, :create_upload_dir_failed}
    end
  end

  defp default_upload_dir do
    :backend
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("uploads")
  end

  defp build_storage_name(original_filename) do
    ext = Path.extname(original_filename)
    base = Path.basename(original_filename, ext) |> sanitize_segment()
    uuid = Ecto.UUID.generate()
    safe_base = if base == "", do: "file", else: String.slice(base, 0, 40)
    {:ok, "#{uuid}-#{safe_base}#{ext}"}
  end

  defp sanitize_segment(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\-_.]+/u, "-")
    |> String.trim("-")
  end

  defp allowed_extension?(filename) do
    ext =
      filename
      |> Path.extname()
      |> String.downcase()

    if ext in @allowed_extensions, do: true, else: {:error, :unsupported_media_type}
  end

  defp allowed_content_type?(content_type) when is_binary(content_type) do
    normalized = String.downcase(String.trim(content_type))
    if normalized in @allowed_content_types, do: true, else: {:error, :unsupported_media_type}
  end

  defp allowed_content_type?(_), do: {:error, :unsupported_media_type}
end
