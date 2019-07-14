//
//  UniversityViewController.swift
//  ViFi
//
//  Created by Emre BÜYÜKER on 13.05.2019.
//  Copyright © 2019 Emre BÜYÜKER. All rights reserved.
//

import UIKit
import Firebase
import FirebaseDatabase

class UniversityViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    
    // MARK - Outles
    
    @IBOutlet weak var universityTableView: UITableView!
    
    // MARK - Public
    
    public var universitiesNameArray = [String]()
    
    // MARK - Life Cycles
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.universityTableView.delegate = self
        self.universityTableView.dataSource = self
    }
    
    override func viewWillAppear(_ animated: Bool) {
        let tabBar = tabBarController as! BaseTabbarVC
        tabBar.tabbarItem.isHidden = false
        
        universitiesNameArray.removeAll()
        getDataFromFireBase()
    }
    
    // MARK - Helpers Methods
    
    func getDataFromFireBase() {
        let dataBaseRefence = Database.database().reference()
        
        dataBaseRefence.child("Universities").observe(DataEventType.childAdded) { (snapshot) in
            self.universitiesNameArray.append(snapshot.key)
            self.universityTableView.reloadData()
        }
    }
    
    // MARK - Table View Methods
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.universitiesNameArray.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = universityTableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath) as! UniversityTableViewCell
        cell.universityLabel.text = universitiesNameArray[indexPath.row]
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let uniName = universitiesNameArray[indexPath.row]
        let tabBar = tabBarController as! BaseTabbarVC
        tabBar.uniNameVariable = uniName
        self.tabBarController?.selectedIndex = 1
    }
}
