terraform {
  required_version = ">= 1.0"
}

resource "null_resource" "marker" {
  triggers = { id = "tf-only-fixture" }
}
