# model-hub-deployment

Infrastructure as code to deploy the Hackolade Model Hub. Each folder is a separate stack:

| Folder | Cloud | Tool | What it deploys |
| --- | --- | --- | --- |
| [resource-manager](resource-manager) | Oracle Cloud | OCI Resource Manager (Terraform) | The Model Hub on OCI |
| [aws](aws) | AWS | Terraform | The guide [Model Hub on Amazon EC2](https://hackolade.com/help/ModelHubonAmazonEC2.html): EC2, RDS for PostgreSQL, Application Load Balancer |
| [azure](azure) | Azure | Bicep | The guide [Model Hub on an Azure virtual machine](https://hackolade.com/help/ModelHubonanAzurevirtualmachine.html): virtual machine, PostgreSQL flexible server, Application Gateway |

The `aws` and `azure` stacks are examples to adapt to your organization. Before you deploy any of them, the Hackolade Helpdesk must have registered the hostname of your Model Hub: see [Model Hub prerequisites](https://hackolade.com/help/ModelHubprerequisites.html).
