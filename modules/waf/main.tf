# Web application firewall in front of the load balancer.
# Every request is checked here before it reaches the application.

variable "name" {
  type = string
}

variable "load_balancer_arn" {
  description = "The load balancer to protect"
  type        = string
}

variable "rate_limit" {
  description = "Most requests one IP address may send in 5 minutes before it is blocked"
  type        = number
  default     = 2000
}

locals {
  # Rule sets written and kept up to date by AWS. Lower number = checked first.
  managed_rules = {
    AWSManagedRulesAmazonIpReputationList = 10 # addresses known for attacks and bots
    AWSManagedRulesCommonRuleSet          = 20 # the common web attacks (OWASP Top 10), such as cross-site scripting
    AWSManagedRulesKnownBadInputsRuleSet  = 30 # request patterns used by known exploits
    AWSManagedRulesSQLiRuleSet            = 40 # SQL injection, important with a SQL Server database behind the app
  }
}

resource "aws_wafv2_web_acl" "this" {
  name  = var.name
  scope = "REGIONAL" # REGIONAL protects a load balancer. CLOUDFRONT is the other scope.

  default_action {
    allow {} # anything no rule objects to is let through
  }

  dynamic "rule" {
    for_each = local.managed_rules
    content {
      name     = rule.key
      priority = rule.value

      override_action {
        none {} # use the rule set's own block decisions. "count {}" would only log, useful when testing a new rule
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.key
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.key
        sampled_requests_enabled   = true
      }
    }
  }

  # Slows down password guessing and floods from a single address.
  rule {
    name     = "rate-limit-per-ip"
    priority = 50

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-per-ip"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = var.name
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "this" {
  resource_arn = var.load_balancer_arn
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}

output "web_acl_arn" {
  value = aws_wafv2_web_acl.this.arn
}
