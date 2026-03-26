defmodule SymphonyElixirWeb.Plugs.DashboardBasicAuth do
  @moduledoc """
  Basic auth guard for the observability dashboard and API.
  """

  import Plug.Conn

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{request_path: "/health"} = conn, _opts), do: conn

  def call(conn, _opts) do
    username = System.get_env("SYMPHONY_DASHBOARD_USERNAME")
    password = System.get_env("SYMPHONY_DASHBOARD_PASSWORD")

    if valid_credentials_present?(username, password) do
      Plug.BasicAuth.basic_auth(conn, username: username, password: password)
    else
      conn
      |> put_resp_header("www-authenticate", ~s(Basic realm="Symphony Dashboard"))
      |> send_resp(401, "Unauthorized")
      |> halt()
    end
  end

  defp valid_credentials_present?(username, password) do
    is_binary(username) and username != "" and is_binary(password) and password != ""
  end

end
