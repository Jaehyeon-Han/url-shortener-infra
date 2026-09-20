module "cognito" {
    source = "./modules/cognito"

    name = var.name
}