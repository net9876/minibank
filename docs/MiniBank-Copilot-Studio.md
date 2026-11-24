# MiniBank lab | From an Entra user to a Copilot Studio agent

**Second user, same lab:** Complete steps 1 and 2, then follow **Use the existing lab** in step 3. Create a new environment only if you want a separate copy or the original trial has expired.

## 1. Create a work account

1. As a **User Administrator** in the lab tenant, open **Entra ID → Users → New user → Create new user**. [Microsoft Entra admin center](https://entra.microsoft.com/) · [Microsoft instructions](https://learn.microsoft.com/en-us/entra/fundamentals/how-to-create-delete-users)
2. Choose a new username such as `minibank02@<tenant>.onmicrosoft.com`, set a display name and initial password, and set the user's **Usage location** under **Properties**. Select **Review + create → Create**.
3. Open a separate browser profile or private window for the lab user. Sign in with the full work username and complete any password change or MFA prompts. Keep the admin session in its original window.

## 2. Activate the user's Copilot Studio trial

Follow the trial sign-up link in Microsoft's access guide while signed in as the new user. Complete the form and select **Get Started**. At **Confirmation details**, check that the username is the new lab account, then continue to Copilot Studio. Landing on **Home** is expected. If the tenant blocks self-service trials, ask its licensing administrator to provide access. [Trial sign-up guide](https://learn.microsoft.com/en-us/microsoft-copilot-studio/sign-up-individual) · [Copilot Studio](https://copilotstudio.microsoft.com/)

## 3. Choose the Dataverse environment

**Use the existing lab.** With the second account, click the environment name at the bottom left of Copilot Studio and select **MiniBank-Lab**. If it is missing or agent creation is denied, have the environment admin open **Manage → Environments → MiniBank-Lab → Settings → Users + permissions → Users**, add or select the account, and check its authoring security role (**Agent Author**, labeled **Bot Author** in some interfaces). If the environment uses a security group, add the user to that group as well. To edit the first user's agent, have its owner share it with the second user as a coauthor. [Power Platform admin center](https://admin.powerplatform.microsoft.com/) · [Copilot Studio environment access](https://learn.microsoft.com/en-us/microsoft-copilot-studio/environments-first-run-experience)

**Create a separate lab.** In the Power Platform admin center, open **Manage → Environments → New**. Enter a unique name, choose **Trial**, select **United States**, and enable **Add Dataverse**. On the next screen, the original lab used **English (United States)**, **USD**, security group **None**, an automatic URL, Dynamics 365 apps **No**, and sample apps/data **Yes** (optional). Save and wait for **State = Ready** and **Dataverse = Yes**. Switch to this environment in Copilot Studio. Record its expiration date. If **Manage** is missing, use an account authorized to create trial environments in that tenant. [Trial environment setup](https://learn.microsoft.com/en-us/power-platform/admin/trial-environments) · [Creation permissions](https://learn.microsoft.com/en-us/power-platform/admin/create-environment)

## 4. Create and test Bank Operations Assistant

**What happened in the first lab.** In **MiniBank-Lab**, **Home → Agent** created a draft named **Bank Operations Assistant**. Opening **Preview** showed **0 credits** and `EnforcementUsageCredits`. At that point the environment and Dataverse were ready. Preview for this agent type can consume Copilot Credits. [Preview and billing](https://learn.microsoft.com/en-us/microsoft-copilot-studio/agents-experience/preview-overview)

**Recommended route for the repeat.** On **Home**, use the link **Explore what else is possible with agents** below the three main cards. Choose **Build a standard agent**, name it **Bank Operations Assistant – Standard**, and enter these instructions. Microsoft documents test-chat access for standard agents on a trial. [Standard agent licensing](https://learn.microsoft.com/en-us/microsoft-copilot-studio/billing-licensing)

> Help MiniBank operations staff investigate delayed payments. Use connected payment records to explain the status. If the records are unavailable or the reason is missing, say so. Ask for confirmation before opening a review case.

Open **Test chat** and ask `What is the status of payment PAY-1042?` Before connecting payment data, expect the agent to say it cannot verify the status. This is the next verification step. The first session ended at the credit error.

**If you see “Dataverse isn't set up in this environment,”** check the environment selector first. In the original session, that message appeared in **Default Directory (default)**. The lab agent belongs in **MiniBank-Lab**.
