defmodule Nopea.Domain.CommitSHATest do
  use ExUnit.Case, async: true

  alias Nopea.Domain.CommitSHA

  @valid_sha "abc123def456789012345678901234567890abcd"
  @short_sha "abc123d"

  describe "new/1" do
    test "creates a commit SHA with valid 40-char hex string" do
      assert {:ok, sha} = CommitSHA.new(@valid_sha)
      assert sha.value == @valid_sha
    end

    test "accepts lowercase hex" do
      sha_lower = "abcdef1234567890abcdef1234567890abcdef12"
      assert {:ok, sha} = CommitSHA.new(sha_lower)
      assert sha.value == sha_lower
    end

    test "normalizes uppercase to lowercase" do
      sha_upper = "ABCDEF1234567890ABCDEF1234567890ABCDEF12"
      assert {:ok, sha} = CommitSHA.new(sha_upper)
      assert sha.value == String.downcase(sha_upper)
    end

    test "rejects SHA that is too short" do
      assert {:error, :invalid_sha} = CommitSHA.new("abc123")
    end

    test "rejects SHA that is too long" do
      too_long = @valid_sha <> "extra"
      assert {:error, :invalid_sha} = CommitSHA.new(too_long)
    end

    test "rejects non-hex characters" do
      invalid = "xyz123def456789012345678901234567890abcd"
      assert {:error, :invalid_sha} = CommitSHA.new(invalid)
    end

    test "rejects empty string" do
      assert {:error, :invalid_sha} = CommitSHA.new("")
    end

    test "rejects nil" do
      assert {:error, :invalid_sha} = CommitSHA.new(nil)
    end
  end

  describe "valid?/1" do
    test "returns true for valid 40-char hex" do
      assert CommitSHA.valid?(@valid_sha)
    end

    test "returns true for uppercase hex" do
      assert CommitSHA.valid?(String.upcase(@valid_sha))
    end

    test "returns false for invalid SHA" do
      refute CommitSHA.valid?("invalid")
      refute CommitSHA.valid?("abc123")
      refute CommitSHA.valid?("")
      refute CommitSHA.valid?(nil)
    end
  end

  describe "short/1" do
    test "returns first 7 characters" do
      {:ok, sha} = CommitSHA.new(@valid_sha)
      assert CommitSHA.short(sha) == @short_sha
    end
  end

  describe "to_string/1" do
    test "returns the full SHA string" do
      {:ok, sha} = CommitSHA.new(@valid_sha)
      assert CommitSHA.to_string(sha) == @valid_sha
    end
  end

  describe "String.Chars protocol" do
    test "allows interpolation in strings" do
      {:ok, sha} = CommitSHA.new(@valid_sha)
      assert "commit: #{sha}" == "commit: #{@valid_sha}"
    end
  end

  describe "equality" do
    test "two SHAs with same value are equal" do
      {:ok, sha1} = CommitSHA.new(@valid_sha)
      {:ok, sha2} = CommitSHA.new(@valid_sha)

      assert sha1 == sha2
    end

    test "SHAs with different case are equal after normalization" do
      {:ok, sha1} = CommitSHA.new(String.downcase(@valid_sha))
      {:ok, sha2} = CommitSHA.new(String.upcase(@valid_sha))

      assert sha1 == sha2
    end
  end

  describe "from_string!/1" do
    test "returns CommitSHA for valid input" do
      sha = CommitSHA.from_string!(@valid_sha)
      assert sha.value == @valid_sha
    end

    test "raises for invalid input" do
      assert_raise ArgumentError, fn ->
        CommitSHA.from_string!("invalid")
      end
    end
  end
end
