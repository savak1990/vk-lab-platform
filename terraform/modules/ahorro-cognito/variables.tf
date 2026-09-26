variable "project" {
  description = "PROJECT_NAME - used to name the pool and build this project's SSM parameter paths."
  type        = string
}

variable "test_user_email" {
  description = "Username of the end-to-end test user. A non-deliverable address is correct: nothing is ever sent to it."
  type        = string
}

variable "test_user_password_secret_path" {
  description = "Absolute path to the KMS-encrypted ciphertext file holding the test user's password."
  type        = string
}
