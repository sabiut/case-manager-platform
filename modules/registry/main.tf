# Image registry for one region. ECR is per region, so every region has its own
# and never depends on another region to start its containers.

variable "name" {
  description = "Repository name, for example cm-ecs-au"
  type        = string
}

resource "aws_ecr_repository" "app" {
  name                 = var.name
  image_tag_mutability = "IMMUTABLE" # a tag always means the same image, so a rollback is exact
  force_delete         = true        # lab only: allows destroy while images exist

  image_scanning_configuration { scan_on_push = true }
}

# Keep the newest 20 images, delete older ones automatically.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the newest 20 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = { type = "expire" }
    }]
  })
}

output "repository_url" {
  value = aws_ecr_repository.app.repository_url
}
