# Openstudio Server CLI

Please begin by referring to the [[getting-started|CLI#getting-started]] section of this document, which ensures that the ruby dependencies of the server are installed via openstudio_meta and that all other required programs are installed and updated. The remainder of the wiki is broken down by target type, [[local|CLI#local]] and [[remote|CLI#remote]], with a two finial sections, one devoted to [[analysis jobs|CLI#jobs]] and the one to [[troubleshooting|CLI#troubleshooting]]. 

Local targets are started and stopped using programs installed on your operating system and are highly-system dependent. As such, we only support OSX Yosemite and above, as well as Windows 7 and up. Currently, we provided limited support for Ubuntu 14.04 and above, as well as most CentOS 6 and 7 systems. For assistance with these systems, please refer to the [[troubleshooting section|CLI#troubleshooting]] or the [HPC knowledge store](https://github.com/NREL/OpenStudio-server/blob/dockerize/docker/HPC.md).

Remote targets are generally grouped into two sets: one's managed externally to the openstudio_meta, and those managed by openstudio_meta (currently only AWS OpenStudio-Server AMI instances.) The former are typically defined by a DNS which is used for running [[analysis jobs|CLI#jobs]], however the later are significantly more complicated and make use of the AWS-SKD. Please refer to the [[remote section|CLI#remote]] for more information.

## Getting-Started

## Local

Currently only use of the local functions of the OpenStudio Meta CLI via PAT are supported. This documentation will be extended to discuss the implementation of that interface at a later date.

## Remote

There are two primary CLI commands which control remote OpenStudio-server instances. These are `start_remote` and `stop_remote`. The `start_remote` command can be used to either ensure that an OpenStudio-Server instance is available at a remote URL or create an instance on Amazon Web Service's (AWS's) Elastic Cloud Computing (EC2) infrastructure. The `stop_remote` command only functions on an AWS EC2 instance, sending a termination signal to AWS which stops and kills the server.

### Non-AWS

To test if a remote OpenStudio-Server instance is alive and responding the `start_remote` command only needs the server's DNS. If the server is alive the command will return a 0 exit code and no messages. If the server is not alive, the command will return a 1 exit code and an error message. The command takes the form of `openstudio_meta start_remote TARGET_DNS` where the TARGET_DNS specifies the server to check the status of.

If the target DNS was `http://www.not-a-real.server:8080` then the example would be:

```sh
ruby openstudio_meta start_remote http://www.not-a-real.server:8080
```

### AWS

Both remote commands use the AWS Ruby SDK to instantiate instances of the OpenStudio-Server on AWS using pre-built Amazon Machine Images (AMIs). To use AWS first an account needs to be created and configured, next several environment variables must be set, followed by defining the server parameters via a JSON document, and finally `openstudio_meta start_remote` must be called with the correct parameters. To stop the server, an output of the `start_remote` command is passed to the `stop_remote` command which provides the information necessary to terminate the EC2 instance.

**NOTE:** After working with EC2 always check the EC2 console dashboard to ensure that all instances have been terminated as expected.

#### Setting Up an Account

1. Begin by going to [AWS] (http://aws.amazon.com). Click the Sign Up button in the top right
   corner.
2. Enter your email or mobile number and click *I am a new user.* before clicking on the *Sign in*
   button.
3. Be aware while progressing through the next screens that it is important to use strong passwords,
   as malicious activity can easily go undetected. Additionally it is important to provide Amazon
   with a phone number you are accessible at so you can be reached in case of potentially fraudulent
   activity on your account.
4. When you reach 'aws.amazon.com/registration-confirmation' click on the Launch Management Console
   button, which should redirect you to 'console.aws.amazon.com/console/home'. Under *Administration
   & Security* click on *Identity & Access Management.* See the links for setting up
   [an MFA](http://docs.aws.amazon.com/IAM/latest/UserGuide/Using_ManagingMFA.html),
   [non-root user](http://docs.aws.amazon.com/IAM/latest/UserGuide/Using_SettingUpUser.html),
   [non-root group permission](http://docs.aws.amazon.com/IAM/latest/UserGuide/GSGHowToCreateAdminsGroup.html),
   and [using the management console](http://docs.aws.amazon.com/awsconsolehelpdocs/latest/gsg/getting-started.html).
   **It is critical to complete all five items listed under Security Status.**
5. **Download, Screenshot, and save your Access Key ID and Secret Access Key when creating a IAM
   User. These will never again be available to you.**  
   *When creating an individual IAM user it is recommended that Internet Explorer not be used, as
   there is a known bug on the page only experienced by IE users.*

Once all five steps have been completed, consider using an [alias]
(http://docs.aws.amazon.com/IAM/latest/UserGuide/AccountAlias.html) for your user account and log
into your non-root account. 

#### Setting the Environment

Three environment variables are required for the `start_remote` command. They are `AWS_ACCESS_KEY`, `AWS_SECRET_KEY`, and `AWS_DEFAULT_REGION`. 

##### `AWS_ACCESS_KEY`

This key specifies the account to create the AMIs on. It is not secret, however should not be shared publicly regardless.

##### `AWS_SECRET_KEY`

This key serves as authentication of any requests to start, stop, or otherwise alter the state of AMIs. It is critically important that it is not shared, and if it is you must immediately suspend the key on your account. See this [help page](http://docs.aws.amazon.com/general/latest/gr/managing-aws-access-keys.html) for step-by-step instructions.

##### `AWS_DEFAULT_REGION`

This key defines which region the EC2 servers should be started in. Currently, OpenStudio-Server AMIs are only made available by default in the us-east-1 region. For help using other regions please contact [@rhorsey](https://github.com/rHorsey) or [@nllong](https://github.com/nllong) at henry.horsey@nrel.gov or nicholas.long@nrel.gov.

##### Setting Environment Variables

We recommend only setting these values in a single shell / cmd.exe at a time. To do so type the following commands for each environment variable specified above, substituting the correct environment variable key and value.

For UNIX/LINUX users:

```sh
export TYPE_ENV_VAR_KEY_HERE=the-environment-variable-value
```

For Windows users:

```cmd
set TYPE_ENV_VAR_KEY_HERE=the-environment-variable-value
```

#### Defining the Remote Server Configuration

A final piece of input is required to utilize EC2 servers, namely, a specification of which servers to use with which AMIs. A server configuration file is required by the `start_remote` command of the following form:

```json
{
   "cluster_name":"example123",
   "user_id":"jdoe",
   "server_instance_type":"c3.2xlarge",
   "worker_instance_type":"c3.2xlarge",
   "worker_node_number":1,
   "aws_tags":[
      "test_instance"
   ],
   "openstudio_server_version":"2.6.1"
}
```

The `cluster_name` field should not contain spaces or unusual characters, however can largely be set at the users descrection. The `user_id` field is used to determine the instance creater / owner in the AWS EC2 meta-data. The viable values of `server_instance_type` and `worker_instance_type` are defined by Amazon [here](https://aws.amazon.com/ec2/instance-types/) in the server model column. The server should have at least 6 cores and substantial storage. The `worker_node_number` can be set to 0, although this tends to result in long analysis runs. the `aws_tags` field allows for institutional identifiers to be passed through to the AWS EC2 metadata. Finally, the `openstudio_server_version` defines which AMI version of the OpenStudio-Server to use. These are documented [here](http://s3.amazonaws.com//openstudio-resources/server/api/v2/amis.json). Once this JSON file is written to disk, the actual `openstudio_meta start_remote` command can be executed.

#### Executing `start_remote`

You should now be able to use the `openstudio_meta start_remote` AWS functionality. The `-s` or `--server_config FILE` argument is used to specify the server configuration JSON file, and the `-p` or `--project DIRECTORY` argument is used to specify where SSH keys and system configuration details should be saved to. The target of the `start_remote` command is `aws`. As such, the command would look like

```sh
ruby openstudio_meta start_remote -s /path/to/my/server/config.json -p /path/to/a/directory aws
# or, with substantial logging
ruby openstudio_meta start_remote -s /path/to/my/server/config.json -p /path/to/a/directory aws --verbose --debug
```

Upon completion, one or more SSH keys will have been created in the project directory (/path/to/a/directory in the example) as well as a JSON defining the details of the cluster created on EC2. This is saved in the project directory as CUSTER_NAME.json, where the CLUSTER_NAME is determined by the `"cluster_name"` value in the server configuration JSON in the previous section (in this case, the file would be found at /path/to/a/directory/example123.json).

#### Stoping the Remote Server

To terminate the EC2 instances created above the `stop_remote` command is used with the only input being the path to the `example123.json` file previously created. It is necessary to have the environment variables discussed above set for this command to work. The example command would be:

```sh
ruby openstudio_meta stop_remote /path/to/a/directory/example123.json
```

As always, check the EC2 console after completing work using AWS to ensure all instances have been terminated.

