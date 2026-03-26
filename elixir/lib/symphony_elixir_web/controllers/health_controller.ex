defmodule SymphonyElixirWeb.HealthController do
  @moduledoc """
  Lightweight health endpoint for deployment checks.
  """

  use Phoenix.Controller, formats: [:html]

  def show(conn, _params) do
    send_resp(conn, 200, "ok")
  end
end
