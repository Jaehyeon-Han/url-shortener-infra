# 루트 도메인에 대한 ACM 퍼블릭 TLS 인증서다. DNS 방식으로 검증한다.
# 와일드카드/서브도메인 없이 루트 도메인 하나만 대상으로 한다.
resource "aws_acm_certificate" "this" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  # 갱신 시 무중단 교체를 위해 새 인증서를 먼저 만든 뒤 기존 것을 제거한다.
  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name      = "${var.name}-certificate"
    Project   = "urlshortener"
    ManagedBy = "terraform"
  }
}

# ACM이 요구하는 DNS 검증 CNAME을 Porkbun DNS에 생성한다.
# domain_validation_options의 각 항목마다 하나씩 만든다(루트 도메인만이라 보통 1개).
#
# ACM의 resource_record_name은 "_abc.jhan.cc." 형태의 FQDN이다.
# Porkbun의 subdomain은 도메인을 제외한 부분("_abc")만 요구하므로,
# ".<domain>."을 제거하고 후행 점도 제거해 subdomain으로 넘긴다.
# content(CNAME 값)도 후행 점을 제거한다.
resource "porkbun_dns_record" "validation" {
  for_each = {
    for o in aws_acm_certificate.this.domain_validation_options : o.domain_name => o
  }

  domain    = var.domain_name
  subdomain = trimsuffix(replace(each.value.resource_record_name, ".${var.domain_name}.", ""), ".")
  type      = "CNAME"
  content   = trimsuffix(each.value.resource_record_value, ".")
  ttl       = 600
}

# 위에서 만든 CNAME이 반영되면 ACM 검증 완료를 대기한다.
# 인증서 → CNAME → 검증의 일직선 의존이라 순환 참조가 없다.
resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in porkbun_dns_record.validation : r.name]
}
