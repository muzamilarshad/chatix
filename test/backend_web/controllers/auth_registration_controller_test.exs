defmodule BackendWeb.AuthRegistrationControllerTest do
  use BackendWeb.ConnCase, async: false

  alias Backend.Repo
  alias Backend.Users.User

  test "register ignores client supplied role and persists operator", %{conn: conn} do
    email = "register-#{System.unique_integer([:positive])}@chatix-lite.local"

    conn =
      post(conn, ~p"/api/auth/register", %{
        "email" => email,
        "password" => "S3curePass123!",
        "name" => "New User",
        "role" => "admin"
      })

    payload = json_response(conn, 201)
    assert payload["user"]["role"] == "operator"

    user = Repo.get_by!(User, email: email)
    assert user.role == "operator"
  end
end
