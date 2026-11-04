QBCore.Shared.ForceJobDefaultDutyAtLogin = true -- true: Force duty state to jobdefaultDuty | false: set duty state from database last saved
QBCore.Shared.Jobs = {
	unemployed = { label = 'Civilian', defaultDuty = true, offDutyPay = false, grades = { ['0'] = { name = 'Freelancer', payment = 10 } } },
	bus = { label = 'Bus', defaultDuty = true, offDutyPay = false, grades = { ['0'] = { name = 'Driver', payment = 50 } } },
	-- pf-news newsroom roles by grade: 0-1 write and submit, 2 publish directly, 3+ edit (review,
	-- breaking, pin, retract); the boss grade runs the news company account
	reporter = {
		label = 'Weazel News',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Journalist', payment = 50 },
			['1'] = { name = 'Reporter', payment = 65 },
			['2'] = { name = 'Senior Reporter', payment = 80 },
			['3'] = { name = 'Editor', payment = 100 },
			['4'] = { name = 'Editor-in-Chief', isboss = true, payment = 125 },
		},
	},
	trucker = { label = 'Trucker', defaultDuty = true, offDutyPay = false, grades = { ['0'] = { name = 'Driver', payment = 50 } } },
	tow = { label = 'Towing', defaultDuty = true, offDutyPay = false, grades = { ['0'] = { name = 'Driver', payment = 50 } } },
	garbage = { label = 'Garbage', defaultDuty = true, offDutyPay = false, grades = { ['0'] = { name = 'Collector', payment = 50 } } },
	vineyard = { label = 'Vineyard', defaultDuty = true, offDutyPay = false, grades = { ['0'] = { name = 'Picker', payment = 50 } } },
	hotdog = { label = 'Hotdog', defaultDuty = true, offDutyPay = false, grades = { ['0'] = { name = 'Sales', payment = 50 } } },

	police = {
		label = 'Law Enforcement',
		type = 'leo',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Recruit', payment = 50 },
			['1'] = { name = 'Officer', payment = 75 },
			['2'] = { name = 'Sergeant', payment = 100 },
			['3'] = { name = 'Lieutenant', payment = 125 },
			['4'] = { name = 'Chief', isboss = true, payment = 150 },
		},
	},
	ambulance = {
		label = 'EMS',
		type = 'ems',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Recruit', payment = 50 },
			['1'] = { name = 'Paramedic', payment = 75 },
			['2'] = { name = 'Doctor', payment = 100 },
			['3'] = { name = 'Surgeon', payment = 125 },
			['4'] = { name = 'Chief', isboss = true, payment = 150 },
		},
	},
	realestate = {
		label = 'Real Estate',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Recruit', payment = 50 },
			['1'] = { name = 'House Sales', payment = 75 },
			['2'] = { name = 'Business Sales', payment = 100 },
			['3'] = { name = 'Broker', payment = 125 },
			['4'] = { name = 'Manager', isboss = true, payment = 150 },
		},
	},
	taxi = {
		label = 'Taxi',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Recruit', payment = 50 },
			['1'] = { name = 'Driver', payment = 75 },
			['2'] = { name = 'Event Driver', payment = 100 },
			['3'] = { name = 'Sales', payment = 125 },
			['4'] = { name = 'Manager', isboss = true, payment = 150 },
		},
	},
	cardealer = {
		label = 'Vehicle Dealer',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Recruit', payment = 50 },
			['1'] = { name = 'Showroom Sales', payment = 75 },
			['2'] = { name = 'Business Sales', payment = 100 },
			['3'] = { name = 'Finance', payment = 125 },
			['4'] = { name = 'Manager', isboss = true, payment = 150 },
		},
	},
	mechanic = {
		label = 'LS Customs',
		type = 'mechanic',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Recruit', payment = 50 },
			['1'] = { name = 'Novice', payment = 75 },
			['2'] = { name = 'Experienced', payment = 100 },
			['3'] = { name = 'Advanced', payment = 125 },
			['4'] = { name = 'Manager', isboss = true, payment = 150 },
		},
	},
	mechanic2 = {
		label = 'LS Customs',
		type = 'mechanic',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Recruit', payment = 50 },
			['1'] = { name = 'Novice', payment = 75 },
			['2'] = { name = 'Experienced', payment = 100 },
			['3'] = { name = 'Advanced', payment = 125 },
			['4'] = { name = 'Manager', isboss = true, payment = 150 },
		},
	},
	mechanic3 = {
		label = 'LS Customs',
		type = 'mechanic',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Recruit', payment = 50 },
			['1'] = { name = 'Novice', payment = 75 },
			['2'] = { name = 'Experienced', payment = 100 },
			['3'] = { name = 'Advanced', payment = 125 },
			['4'] = { name = 'Manager', isboss = true, payment = 150 },
		},
	},
	beeker = {
		label = 'Beeker\'s Garage',
		type = 'mechanic',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Recruit', payment = 50 },
			['1'] = { name = 'Novice', payment = 75 },
			['2'] = { name = 'Experienced', payment = 100 },
			['3'] = { name = 'Advanced', payment = 125 },
			['4'] = { name = 'Manager', isboss = true, payment = 150 },
		},
	},
	bennys = {
		label = 'Benny\'s Original Motor Works',
		type = 'mechanic',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Recruit', payment = 50 },
			['1'] = { name = 'Novice', payment = 75 },
			['2'] = { name = 'Experienced', payment = 100 },
			['3'] = { name = 'Advanced', payment = 125 },
			['4'] = { name = 'Manager', isboss = true, payment = 150 },
		},
	},
	-- Justice and corrections (batch 15H, owner decision D7). Grade numbers are read by other resources:
	-- pf-government Config.Departments.Implied (qualifications per grade, ManagerGrade) and pf-justice
	-- (CourtJobs, OfficerJobs). Pay is a conservative default for the owner to set: corrections sits a
	-- little under police grade for grade, doj staff between a civilian job and a police sergeant, and
	-- a magistrate keeps the old judge pay. Changing a grade number means changing those configs too.
	corrections = {
		label = 'Department of Corrections',
		type = 'corrections',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Cadet', payment = 45 },
			['1'] = { name = 'Corrections Officer', payment = 65 },
			['2'] = { name = 'Senior Officer', payment = 80 },
			['3'] = { name = 'Sergeant', payment = 95 },
			['4'] = { name = 'Deputy Warden', payment = 115 },
			['5'] = { name = 'Warden', isboss = true, payment = 140 },
		},
	},
	doj = {
		label = 'Department of Justice',
		type = 'doj',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Court Clerk', payment = 55 },
			['1'] = { name = 'Prosecutor', payment = 85 },
			['2'] = { name = 'Public Defender', payment = 85 },
			['3'] = { name = 'Probation Officer', payment = 75 },
			['4'] = { name = 'Chief of Justice', isboss = true, payment = 130 },
		},
	},
	judge = {
		label = 'Judiciary',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Magistrate', payment = 100 },
			['1'] = { name = 'Judge', payment = 125 },
			['2'] = { name = 'Chief Judge', isboss = true, payment = 150 },
		},
	},
	-- grade 0 is the old single Associate grade, so existing lawyers keep their job and pay
	lawyer = {
		label = 'Law Firm',
		defaultDuty = true,
		offDutyPay = false,
		grades = {
			['0'] = { name = 'Associate', payment = 50 },
			['1'] = { name = 'Junior Partner', payment = 70 },
			['2'] = { name = 'Senior Partner', payment = 90 },
			['3'] = { name = 'Managing Partner', isboss = true, payment = 110 },
		},
	},
	government = {
		label = 'Government',
		defaultDuty = true,
		grades = {
			['0'] = { name = 'Utility Manager', payment = 50 },
			['1'] = { name = 'Clerk', payment = 75 },
			['2'] = { name = 'Treasurer', payment = 100 },
			['3'] = { name = 'Deputy Mayor', payment = 150 },
			['4'] = { name = 'Mayor', payment = 200 },
		},
	},
}
