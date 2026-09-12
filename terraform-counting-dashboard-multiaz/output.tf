output "dashboard_url" {
  description = "URL for the dashboard service, open this in a browser"
  value       = "http://${aws_lb.alb.dns_name}"
}

output "alb_dns_name" {
  description = "Public DNS name of the ALB"
  value       = aws_lb.alb.dns_name
}

output "target_group_arn" {
  description = "Use with aws elbv2 describe-target-health --target-group-arn"
  value       = aws_lb_target_group.alb_tg.arn
}

output "asg_name" {
  description = "Auto Scaling Group name, for watching scaling activity"
  value       = aws_autoscaling_group.dashboard_asg.name
}