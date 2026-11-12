import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../app/gateway.dart';
import 'design.dart';
import 'pickup_map.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen(this.controller, {super.key});
  final AppController controller;
  @override
  Widget build(BuildContext context) {
    final driver = controller.kind == AppKind.driver;
    final receiver = controller.kind == AppKind.receiver;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Row(
              children: [
                Expanded(child: Brand(driver: driver)),
                const Tag('GH'),
              ],
            ),
            const SizedBox(height: 28),
            ClipRRect(
              borderRadius: BorderRadius.circular(32),
              child: SizedBox(
                height: 260,
                child: Stack(
                  children: [
                    const Positioned.fill(child: PickupMap(demo: true)),
                    Positioned(
                      left: 18,
                      right: 18,
                      bottom: 40,
                      child: Panel(
                        padding: 14,
                        child: Row(
                          children: [
                            Icon(
                              driver
                                  ? Icons.local_shipping_rounded
                                  : Icons.recycling,
                              color: ink,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                driver
                                    ? 'A cleaner city starts with you.'
                                    : 'Less waste. More possibility.',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 30),
            Text(
              receiver
                  ? 'Every pickup.\nAccounted for.'
                  : driver
                  ? 'Good work.\nGreener streets.'
                  : 'A cleaner space,\na tap away.',
              style: Theme.of(context).textTheme.headlineLarge,
            ),
            const SizedBox(height: 14),
            Text(
              receiver
                  ? 'Sign in to review and confirm collections at your warehouse.'
                  : driver
                  ? 'Your collections, your route and everything you need for the day.'
                  : 'Book a waste collection in East Legon. Follow your pickup from your doorstep to the receiving warehouse.',
              style: const TextStyle(fontSize: 16, color: muted, height: 1.5),
            ),
            const SizedBox(height: 26),
            ActionButton(
              receiver ? 'Sign in' : 'Get started',
              onPressed: () async =>
                  openPage(context, AuthScreen(controller, signup: !receiver)),
            ),
            if (!receiver)
              TextButton(
                onPressed: () => openPage(context, AuthScreen(controller)),
                child: const Text('Already have an account? Sign in'),
              ),
            if (controller.gateway.demo)
              TextButton.icon(
                onPressed: () async {
                  await controller.gateway.authenticate('preview', 'preview');
                  await controller.refresh();
                },
                icon: const Icon(Icons.play_circle_outline),
                label: const Text('Explore prototype'),
              ),
            const SizedBox(height: 10),
            const Text(
              'Simple collections. Clear prices. Responsible handoffs.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: muted),
            ),
          ],
        ),
      ),
    );
  }
}

class AuthScreen extends StatefulWidget {
  const AuthScreen(this.controller, {super.key, this.signup = false});
  final AppController controller;
  final bool signup;
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final form = GlobalKey<FormState>();
  final identity = TextEditingController(),
      password = TextEditingController(),
      code = TextEditingController();
  bool phone = false, verify = false, obscure = true;
  @override
  void dispose() {
    identity.dispose();
    password.dispose();
    code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        verify
            ? 'Verify your account'
            : widget.signup
            ? 'Create account'
            : 'Welcome back',
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        sectionTitle(
          context,
          verify
              ? 'One more step'
              : widget.signup
              ? 'Let’s get you started'
              : 'Ready when you are',
          verify
              ? 'Use the verification code or email link sent to ${identity.text}.'
              : 'Sign in with your email or Ghana phone number.',
        ),
        Form(
          key: form,
          child: Column(
            children: [
              if (!verify) ...[
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Email')),
                    ButtonSegment(value: true, label: Text('Phone')),
                  ],
                  selected: {phone},
                  onSelectionChanged: (v) => setState(() => phone = v.first),
                ),
                const SizedBox(height: 24),
                TextFormField(
                  controller: identity,
                  autofillHints: phone
                      ? const [AutofillHints.telephoneNumber]
                      : const [AutofillHints.email],
                  keyboardType: phone
                      ? TextInputType.phone
                      : TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: phone ? 'Phone number (+233…)' : 'Email address',
                  ),
                  validator: (v) => phone
                      ? RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(v?.trim() ?? '')
                            ? null
                            : 'Use international format, for example +233…'
                      : RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                            .hasMatch(v?.trim() ?? '')
                      ? null
                      : 'Enter a valid email address',
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: password,
                  obscureText: obscure,
                  autofillHints: const [AutofillHints.password],
                  decoration: InputDecoration(
                    labelText: 'Password',
                    suffixIcon: IconButton(
                      tooltip: obscure ? 'Show password' : 'Hide password',
                      onPressed: () => setState(() => obscure = !obscure),
                      icon: Icon(
                        obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                  ),
                  validator: (v) =>
                      (v?.length ?? 0) < 8 ? 'Use at least 8 characters' : null,
                ),
              ] else
                TextFormField(
                  controller: code,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Verification code',
                  ),
                  validator: (v) =>
                      (v?.trim().isEmpty ?? true) ? 'Enter your code' : null,
                ),
              const SizedBox(height: 24),
              ActionButton(
                verify
                    ? 'Verify account'
                    : widget.signup
                    ? 'Create account'
                    : 'Sign in',
                onPressed: () async {
                  if (!form.currentState!.validate()) return;
                  if (verify) {
                    await widget.controller.gateway.verify(
                      identity.text.trim(),
                      code.text.trim(),
                    );
                  } else {
                    await widget.controller.gateway.authenticate(
                      identity.text.trim(),
                      password.text,
                      signup: widget.signup,
                    );
                  }
                  await widget.controller.refresh();
                  if (!context.mounted) return;
                  if (widget.controller.signedIn) {
                    Navigator.of(context).popUntil((r) => r.isFirst);
                  } else if (widget.signup) {
                    setState(() => verify = true);
                  }
                },
              ),
              if (verify)
                TextButton(
                  onPressed: () async {
                    try {
                      await widget.controller.gateway.resend(
                        identity.text.trim(),
                      );
                      if (context.mounted) {
                        message(
                          context,
                          'Verification sent. Check your messages.',
                        );
                      }
                    } catch (e) {
                      if (context.mounted) message(context, friendlyError(e));
                    }
                  },
                  child: const Text('Resend verification'),
                ),
              if (!verify && !widget.signup)
                TextButton(
                  onPressed: () =>
                      openPage(context, RecoveryScreen(widget.controller)),
                  child: const Text('Forgot password?'),
                ),
            ],
          ),
        ),
        if (widget.controller.gateway.demo)
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: Notice(
              'Prototype accounts stay on this device session. No email or SMS is sent.',
            ),
          ),
      ],
    ),
  );
}

class RecoveryScreen extends StatefulWidget {
  const RecoveryScreen(this.controller, {super.key, this.update = false});
  final AppController controller;
  final bool update;
  @override
  State<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends State<RecoveryScreen> {
  final value = TextEditingController();
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Account recovery')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        sectionTitle(
          context,
          widget.update ? 'Choose a new password' : 'Reset your password',
          widget.update ? 'Use a password you have not used before.' : 'We’ll send a recovery link to your email. Phone-only accounts need operator assistance for now.',
        ),
        Form(
          key: form,
          child: TextFormField(
            controller: value,
            obscureText: widget.update,
            decoration: InputDecoration(
              labelText: widget.update ? 'New password' : 'Email address',
            ),
            validator: (v) => widget.update
                ? (v?.length ?? 0) < 8
                      ? 'Use at least 8 characters'
                      : null
                : (v?.contains('@') ?? false)
                ? null
                : 'Enter your email',
          ),
        ),
        const SizedBox(height: 24),
        ActionButton(
          widget.update ? 'Save password' : 'Send recovery email',
          onPressed: () async {
            if (!form.currentState!.validate()) return;
            if (widget.update) {
              await widget.controller.gateway.updatePassword(value.text);
              await widget.controller.refresh();
            } else {
              await widget.controller.gateway.resetPassword(value.text.trim());
              if (context.mounted) {
                message(
                  context,
                  'If the account exists, a recovery email is on its way.',
                );
              }
            }
          },
        ),
      ],
    ),
  );
}

class EnrollmentScreen extends StatefulWidget {
  const EnrollmentScreen(this.controller, {super.key});
  final AppController controller;
  @override
  State<EnrollmentScreen> createState() => _EnrollmentScreenState();
}

class _EnrollmentScreenState extends State<EnrollmentScreen> {
  final name = TextEditingController();
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Your profile')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        sectionTitle(
          context,
          'What should we call you?',
          'Your name helps your driver identify the right collection.',
        ),
        Form(
          key: form,
          child: TextFormField(
            controller: name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Full name'),
            validator: (v) =>
                (v?.trim().length ?? 0) < 2 ? 'Enter your full name' : null,
          ),
        ),
        const SizedBox(height: 24),
        ActionButton(
          'Continue',
          onPressed: () async {
            if (form.currentState!.validate()) {
              await widget.controller.act('client.register', {
                'full_name': name.text.trim(),
              }, onboarding: true);
            }
          },
        ),
        TextButton(
          onPressed: () => widget.controller.gateway.signOut(),
          child: const Text('Sign out'),
        ),
      ],
    ),
  );
}
