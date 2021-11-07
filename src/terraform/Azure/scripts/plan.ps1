$fileName = "dev.terraform.tfstate"
$serviceName = "aadlicense"
$environment = "dev"

terraform plan -input=false `
    -var="service_name=${serviceName}" `
    -var-file=".\config\base.tfvars" `
    -var-file=".\config\${environment}.tfvars" `
    -out "${fileName}.tfplan"