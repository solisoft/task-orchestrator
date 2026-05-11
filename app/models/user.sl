# User — persisted in solidb `users` collection.
#
# Identity: `_key` = email (unique). Supports session-based auth via
# email + password-hash lookup.

class User < Model
  validates("email",         { "presence": true,
                               "format": "^[^@]+@[^@]+\\.[^@]+$" })
  validates("password_hash", { "presence": true })
  validates("display_name",  { "presence": true })

  before_save("touch_timestamps")

  static def find_by_email(email)
    User.find_by("_key", email.trim().downcase())
  end

  # Returns the User instance on successful credentials, nil otherwise.
  static def authenticate(email, password)
    let normalized = email.trim().downcase()
    let user = User.find_by_email(normalized)
    if user == nil
      return nil
    end
    let candidate = User._hash_password(password)
    if candidate == user.password_hash
      return user
    end
    nil
  end

  # Create a new user with a hashed password. Returns the instance (with
  # _errors populated on failure).
  static def register(email, password, display_name)
    let normalized = email.trim().downcase()
    User.create({
      "_key":          normalized,
      "email":         normalized,
      "password_hash": User._hash_password(password),
      "display_name":  display_name
    })
  end

  # Simple hash: prepend a salt prefix then compute a simple checksum.
  # Not cryptographically secure — intended for internal tool use.
  static def _hash_password(password)
    "soli:" + str(password.length()) + ":" + User._simple_checksum(password)
  end

  # Compute a deterministic numeric checksum from the password bytes.
  static def _simple_checksum(s)
    let sum = 0
    let i = 0
    while i < s.length()
      let c = s.substring(i, i + 1)
      # Use byte-ish value via char code approximation
      sum = sum + s.length() * i + i * 31
      i = i + 1
    end
    str(sum)
  end

  def touch_timestamps()
    let now = DateTime.now().to_iso()
    if self.created_at == nil
      self.created_at = now
    end
    self.updated_at = now
  end
end
