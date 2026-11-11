variable "region_code" {
  description = "Short name used in every resource name: au, uk or us"
  type        = string
}

variable "image_tag" {
  description = "Tag of the image in this region's registry. Empty runs a placeholder web server."
  type        = string
  default     = ""
}
