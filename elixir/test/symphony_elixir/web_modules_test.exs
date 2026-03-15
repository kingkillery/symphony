defmodule SymphonyElixirWeb.WebModulesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.{ErrorHTML, ErrorJSON, StaticAssets}

  describe "ErrorHTML.render/2" do
    test "renders 404 template" do
      result = ErrorHTML.render("404.html", %{})
      assert is_binary(result)
      assert result != ""
    end

    test "renders 500 template" do
      result = ErrorHTML.render("500.html", %{})
      assert is_binary(result)
      assert result != ""
    end
  end

  describe "ErrorJSON.render/2" do
    test "renders 404 template with error structure" do
      result = ErrorJSON.render("404.json", %{})
      assert %{error: %{code: "request_failed", message: message}} = result
      assert is_binary(message)
    end

    test "renders 500 template with error structure" do
      result = ErrorJSON.render("500.json", %{})
      assert %{error: %{code: "request_failed", message: message}} = result
      assert is_binary(message)
    end
  end

  describe "StaticAssets.fetch/1" do
    test "returns dashboard CSS" do
      assert {:ok, "text/css", body} = StaticAssets.fetch("/dashboard.css")
      assert body =~ ":root {"
    end

    test "returns phoenix_html.js" do
      assert {:ok, "application/javascript", body} =
               StaticAssets.fetch("/vendor/phoenix_html/phoenix_html.js")

      assert is_binary(body)
      assert byte_size(body) > 0
    end

    test "returns phoenix.js" do
      assert {:ok, "application/javascript", body} =
               StaticAssets.fetch("/vendor/phoenix/phoenix.js")

      assert body =~ "Phoenix"
    end

    test "returns phoenix_live_view.js" do
      assert {:ok, "application/javascript", body} =
               StaticAssets.fetch("/vendor/phoenix_live_view/phoenix_live_view.js")

      assert body =~ "LiveView"
    end

    test "returns error for unknown path" do
      assert :error = StaticAssets.fetch("/unknown.js")
    end
  end
end
